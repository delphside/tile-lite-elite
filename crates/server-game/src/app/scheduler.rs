//! #400 — periodic scans over derived state, run without a request having
//! arrived. `#166`'s settled design generalised: nothing persisted (a job
//! is a scan over state that already implies what is due), one run before
//! the first interval, `MissedTickBehavior::Delay` so a slow pass is never
//! chased, and two frequency scales because most deadlines have hour-scale
//! tolerance and the retirement broadcast does not.
//!
//! **A workstream adds a job by adding it to the list built at startup** —
//! `scheduler_jobs::spawn_scheduler`, deliberately a separate file, not
//! this one. Nothing here names a job, so R6 ("design to it") is a fact
//! about the shape of this module, not a promise about it — and it stays
//! true because growing the job list can never touch the engine below.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Mutex;
use tokio::time::MissedTickBehavior;

use super::AppState;
use crate::game_state::now_unix_seconds;

/// A deadline someone is watching expire lives here — the retirement
/// broadcast, R4's justification for a second scale at all.
pub(crate) const FAST_INTERVAL: Duration = Duration::from_secs(5);
/// Everything else's default tolerance is hours, not seconds.
pub(crate) const SLOW_INTERVAL: Duration = Duration::from_secs(60 * 60);

/// One thing to run on a cadence. `run` does the work and returns how many
/// items in that pass errored — `0` for a clean pass. Errors are still
/// logged at the call site exactly as before; this count is what R5's
/// health numbers read, not a replacement for the log.
///
/// **A job carries no interval of its own.** The tier it is spawned on
/// (`spawn`) has one, and `run_once` records that as the job's
/// `expected_interval`. Written once, so the cadence a job runs on and the
/// cadence `check_for_stalled_jobs` judges it against cannot drift apart;
/// when both were arguments, nothing stopped them disagreeing (#415).
pub(crate) struct Job {
    pub(crate) name: &'static str,
    run: Box<dyn Fn() -> Pin<Box<dyn Future<Output = u64> + Send>> + Send + Sync>,
}

impl Job {
    /// Wraps an `async fn(&AppState) -> u64` as a job, cloning `state` into
    /// the closure once and re-cloning it (cheap — every field is an `Arc`,
    /// a `Pool`, or a `Sender`) on each call, since a job runs forever and a
    /// borrow can't outlive one pass.
    pub(crate) fn new<F, Fut>(name: &'static str, state: AppState, run: F) -> Self
    where
        F: Fn(AppState) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = u64> + Send + 'static,
    {
        Self {
            name,
            run: Box::new(move || Box::pin(run(state.clone()))),
        }
    }
}

/// Last-completed timestamp (epoch seconds, UTC — `docs` timestamp
/// convention), errored-item count, and expected cadence for a job's most
/// recent pass. `last_completed_at: None`/`errored_last_pass: 0` until the
/// job has ever completed a pass, which reads the same as "never run" —
/// the check this exists for (`admin_scheduler_health`) is read by an
/// operator who already knows whether the server just started.
///
/// `last_completed_instant` carries the same moment on `Instant`, which
/// `check_for_stalled_jobs` (`scheduler_jobs.rs`) reads instead of
/// `last_completed_at` for exactly the reason `Instant` exists: it is
/// guaranteed monotonic, where `last_completed_at`'s wall clock can jump
/// in either direction (NTP sync, VM resume) and silently mask a real
/// stall or manufacture a false one. `last_completed_at` stays the field
/// `/admin/scheduler-health` reports, since an operator wants a real
/// calendar time, not an opaque monotonic tick.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct JobHealth {
    pub(crate) last_completed_at: Option<i64>,
    pub(crate) last_completed_instant: Option<std::time::Instant>,
    pub(crate) errored_last_pass: u64,
    pub(crate) expected_interval: Duration,
}

pub(crate) type SchedulerHealth = Arc<Mutex<HashMap<&'static str, JobHealth>>>;

/// Runs every job in `jobs` once, sequentially, updating `health` after
/// each. Split out from the interval loop so a job running "without a
/// request having arrived" (R1) is something a test can call directly,
/// with no clock to wait on and no handler in the call stack.
///
/// **Each job runs in its own `tokio::spawn`ed task, awaited here rather
/// than polled directly.** A job that panics would otherwise unwind
/// straight through this function and the `loop` in `spawn` around it,
/// silently ending that whole frequency tier until a restart — nothing
/// would increment `errored_last_pass`, and `last_completed_at` would
/// simply stop advancing with no signal beyond its own staleness. Awaiting
/// a `JoinHandle` isolates the panic: a broken job becomes a recorded
/// failure and the pass, and the next job in the list, carry on.
pub(crate) async fn run_once(jobs: &[Job], expected_interval: Duration, health: &SchedulerHealth) {
    for job in jobs {
        let errored = match tokio::spawn((job.run)()).await {
            Ok(errored) => errored,
            Err(join_error) => {
                tracing::error!(job = job.name, %join_error, "job panicked");
                1
            }
        };
        health.lock().await.insert(
            job.name,
            JobHealth {
                last_completed_at: Some(now_unix_seconds()),
                last_completed_instant: Some(std::time::Instant::now()),
                errored_last_pass: errored,
                expected_interval,
            },
        );
    }
}

/// Spawns a task that calls `run_once` on `interval`, forever.
///
/// `tokio::time::interval`'s first tick resolves immediately rather than
/// after one period, so the first pass runs as soon as the task is polled —
/// a restart does not delay a pending deadline by a full period (R2/R3).
/// `MissedTickBehavior::Delay` means a pass that overran its interval is
/// never made up for: the next tick is `interval` after the late pass
/// *finished*, not backfilled to the original schedule, so a slow pass
/// cannot pile up behind itself.
pub(crate) fn spawn(jobs: Vec<Job>, interval: Duration, health: SchedulerHealth) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            run_once(&jobs, interval, &health).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn empty_health() -> SchedulerHealth {
        Arc::new(Mutex::new(HashMap::new()))
    }

    #[tokio::test]
    async fn run_once_records_a_clean_pass_and_a_dirty_one() {
        let health = empty_health();
        let jobs = vec![
            Job {
                name: "clean",
                run: Box::new(|| Box::pin(async { 0u64 })),
            },
            Job {
                name: "dirty",
                run: Box::new(|| Box::pin(async { 2u64 })),
            },
        ];

        run_once(&jobs, Duration::from_secs(1), &health).await;

        let recorded = health.lock().await;
        let clean = recorded.get("clean").expect("clean job should have run");
        assert_eq!(clean.errored_last_pass, 0);
        assert!(clean.last_completed_at.is_some());

        let dirty = recorded.get("dirty").expect("dirty job should have run");
        assert_eq!(
            dirty.errored_last_pass, 2,
            "R5: an errored pass is a different number from a clean one"
        );
        assert!(dirty.last_completed_at.is_some());
    }

    #[tokio::test]
    async fn a_panicking_job_is_recorded_as_errored_rather_than_killing_the_pass() {
        let health = empty_health();
        let jobs = vec![
            Job {
                name: "panics",
                run: Box::new(|| Box::pin(async { panic!("deliberately broken") })),
            },
            Job {
                name: "still-runs-after",
                run: Box::new(|| Box::pin(async { 0u64 })),
            },
        ];

        run_once(&jobs, Duration::from_secs(1), &health).await;

        let recorded = health.lock().await;
        let panicked = recorded
            .get("panics")
            .expect("a panicking job should still be recorded, not just vanish");
        assert!(
            panicked.errored_last_pass > 0,
            "a panic must count as an errored pass"
        );
        assert!(
            panicked.last_completed_at.is_some(),
            "last_completed_at must keep moving, or a repeatedly panicking job reads as merely stale rather than broken"
        );

        let after = recorded
            .get("still-runs-after")
            .expect("the job after the panicking one must still run in the same pass");
        assert_eq!(after.errored_last_pass, 0);
    }

    #[tokio::test]
    async fn the_expected_interval_recorded_is_the_tiers_own() {
        // #415: the cadence a job is judged against comes from the tier it
        // ran on, so it cannot disagree with the cadence it actually has.
        let health = empty_health();
        let jobs = vec![Job {
            name: "on-a-tier",
            run: Box::new(|| Box::pin(async { 0u64 })),
        }];

        run_once(&jobs, Duration::from_secs(3600), &health).await;

        let recorded = health.lock().await;
        assert_eq!(
            recorded.get("on-a-tier").map(|h| h.expected_interval),
            Some(Duration::from_secs(3600))
        );
    }

    #[tokio::test]
    async fn run_once_runs_a_job_that_never_touches_a_handler() {
        // R1: proven without a handler in the call stack — this test never
        // builds a router or sends a request, and the job still runs.
        let ran = Arc::new(AtomicU64::new(0));
        let counter = ran.clone();
        let jobs = vec![Job {
            name: "counts-its-own-runs",
            run: Box::new(move || {
                let counter = counter.clone();
                Box::pin(async move {
                    counter.fetch_add(1, Ordering::SeqCst);
                    0
                })
            }),
        }];

        run_once(&jobs, Duration::from_secs(1), &empty_health()).await;

        assert_eq!(ran.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn the_first_tick_does_not_wait_a_full_interval() {
        // R2/R3: a restart must not delay every pending deadline by a full
        // period. `tokio::time::interval`'s documented first-tick behaviour
        // is what R2 relies on — this pins that fact against this crate's
        // tokio version rather than trusting it by citation.
        let mut ticker = tokio::time::interval(Duration::from_secs(3600));
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

        tokio::time::timeout(Duration::from_millis(0), ticker.tick())
            .await
            .expect("the first tick must resolve without advancing the clock at all");
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_pass_does_not_pile_up_behind_itself() {
        // R3: with `Delay`, ticks lost while a pass overran are dropped
        // rather than queued — advancing the clock by several periods must
        // produce exactly one more immediately-ready tick, not a burst.
        let interval = Duration::from_secs(10);
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        ticker.tick().await; // the free first tick

        tokio::time::advance(interval * 5).await;
        ticker.tick().await; // due, and ready without a further wait

        tokio::time::timeout(Duration::from_millis(0), ticker.tick())
            .await
            .expect_err(
                "a second tick must not be immediately ready too — that would be the pile-up",
            );
    }
}
