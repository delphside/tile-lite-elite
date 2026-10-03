//! Which jobs the scheduler (`scheduler.rs`) actually runs, kept apart from
//! the engine on purpose: a workstream adding a job edits this file, never
//! `Job`, `run_once` or `spawn`, so growing the list carries no risk of
//! changing behaviour those already have tests for.

use std::time::Duration;

use super::AppState;
use super::scheduler::{FAST_INTERVAL, Job, SLOW_INTERVAL, SchedulerHealth, spawn};

/// The watchdog's own cadence — deliberately a distinct constant from
/// `FAST_INTERVAL` even though it happens to share the same value, so
/// nothing here is "the watchdog runs on `FAST_INTERVAL`" by an
/// assumption that could later stop being true if `FAST_INTERVAL` changed
/// for a reason of its own.
const WATCHDOG_INTERVAL: Duration = Duration::from_secs(5);

/// A margin over a job's own `expected_interval` before its staleness
/// counts as stalled rather than ordinary jitter — generous enough that a
/// single slow-but-not-hung pass never trips it, tight enough that a
/// genuinely stuck job is caught within a few of its own cycles rather
/// than an arbitrary fixed delay.
const STALL_MARGIN: u32 = 3;

/// Reads every job's own recorded health and counts how many have gone
/// stale by more than `STALL_MARGIN` times their own expected cadence —
/// the case `run_once`'s panic isolation cannot reach on its own, because
/// a *hung* job (stuck rather than panicking) never returns at all, so
/// nothing ever unwinds for anything to catch.
///
/// Being a job itself is what makes a stall an *active* signal: this
/// function's own `errored_last_pass` goes nonzero on `/admin/scheduler-health`
/// rather than the stalled job's `last_completed_at` merely sitting there,
/// unwatched, until a person happens to check it. Takes `&SchedulerHealth`
/// rather than `&AppState` — the only thing it reads — so a test can build
/// one directly instead of standing up a whole application.
///
/// **Judges staleness by `last_completed_instant`, never `last_completed_at`.**
/// The latter is wall-clock and can jump either way — an NTP sync or a VM
/// resume-from-suspend would otherwise mask a genuine stall (clock stepped
/// backward) or manufacture a false one (clock stepped forward) on exactly
/// the mechanism built to catch a hang without anyone watching for it.
/// `Instant` is guaranteed monotonic against exactly that.
///
/// A job that has never completed a single pass is not flagged — the
/// first tick resolves immediately (R2), so "never run" should only ever
/// be momentarily true right after startup, and flagging it would be a
/// false positive on every boot.
async fn check_for_stalled_jobs(scheduler_health: &SchedulerHealth) -> u64 {
    let now = std::time::Instant::now();
    let mut stalled = 0u64;
    for (name, health) in scheduler_health.lock().await.iter() {
        let Some(last_completed_instant) = health.last_completed_instant else {
            continue;
        };
        let allowed = health.expected_interval * STALL_MARGIN;
        if now.duration_since(last_completed_instant) > allowed {
            tracing::error!(
                job = name,
                last_completed_at = health.last_completed_at,
                "job appears stalled"
            );
            stalled += 1;
        }
    }
    stalled
}

/// Wires the scheduler's first two customers — `#400`'s deliveries table
/// names four; `#87`'s message-arrived notification and RET-3's countdown
/// are new game behaviour and stay off this until built and reviewed. These
/// two already exist and already run (lazily, from `list_games`); this
/// moves *when* they run, not what they do.
///
/// **`check_for_stalled_jobs` runs on a tier of its own**, third alongside
/// `FAST` and `SLOW` — not sharing either. `run_once` runs a tier's jobs
/// in sequence, so a watchdog sharing a tier with anything else can only
/// ever reliably watch the *other* tier: a hang earlier in its own tier's
/// list freezes it too. On its own tier nothing can share that fate —
/// each tier is an independent `tokio::spawn`ed task, so a hang in
/// `expire_overdue_turns` or `send_move_time_reminders` cannot block the
/// watchdog's task, and the watchdog itself has nothing in it that could
/// hang (a mutex lock and a map iteration, no I/O). It still watches
/// every job's health regardless of which tier that job is on.
pub fn spawn_scheduler(state: AppState) {
    for (interval, jobs) in tiers(&state) {
        spawn(jobs, interval, state.scheduler_health.clone());
    }
}

/// Every tier, as its interval and the jobs that run on it. The interval
/// is written here once per tier and nowhere per job (`scheduler::Job`), and
/// this is what a test reads to prove each job is on the tier it belongs to.
pub(crate) fn tiers(state: &AppState) -> Vec<(Duration, Vec<Job>)> {
    vec![
        (
            FAST_INTERVAL,
            vec![Job::new(
                "expire_overdue_turns",
                state.clone(),
                |state| async move { super::sweeps_game::expire_overdue_turns(&state).await },
            )],
        ),
        (
            SLOW_INTERVAL,
            vec![Job::new(
                "send_move_time_reminders",
                state.clone(),
                |state| async move { super::sweeps_game::send_move_time_reminders(&state).await },
            )],
        ),
        (
            WATCHDOG_INTERVAL,
            vec![Job::new(
                "check_for_stalled_jobs",
                state.clone(),
                |state| async move { check_for_stalled_jobs(&state.scheduler_health).await },
            )],
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::scheduler::JobHealth;
    use crate::game_state::now_unix_seconds;
    use std::collections::HashMap;
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tokio::sync::Mutex;

    /// `ago: None` means never run; `Some(d)` means last completed `d` ago,
    /// as a real (not tokio-paused) `Instant` — `check_for_stalled_jobs`
    /// reads `last_completed_instant`, which paused tokio time does not
    /// affect, so tests build genuine past instants by subtracting rather
    /// than by advancing a virtual clock.
    fn health_with(entries: &[(&'static str, Option<Duration>, Duration)]) -> SchedulerHealth {
        let mut map = HashMap::new();
        for (name, ago, expected_interval) in entries {
            map.insert(
                *name,
                JobHealth {
                    last_completed_at: ago.map(|_| now_unix_seconds()),
                    last_completed_instant: ago.map(|ago| Instant::now() - ago),
                    errored_last_pass: 0,
                    expected_interval: *expected_interval,
                },
            );
        }
        Arc::new(Mutex::new(map))
    }

    /// #415: nothing else would notice a job on the wrong tier. Its work
    /// would still be done, only at the wrong cadence: turn expiry hourly,
    /// or the watchdog sharing a tier with a job it is meant to outlive.
    #[tokio::test]
    async fn each_job_is_on_the_tier_it_belongs_to() {
        let url = crate::app::tests::test_database_url();
        let state = crate::app::tests::create_test_state(&url).await;

        let placed: Vec<(Duration, Vec<&str>)> = tiers(&state)
            .into_iter()
            .map(|(interval, jobs)| (interval, jobs.iter().map(|job| job.name).collect()))
            .collect();

        assert_eq!(
            placed,
            vec![
                (Duration::from_secs(5), vec!["expire_overdue_turns"]),
                (
                    Duration::from_secs(60 * 60),
                    vec!["send_move_time_reminders"]
                ),
                (Duration::from_secs(5), vec!["check_for_stalled_jobs"]),
            ],
            "turn expiry is watched as it happens (#166), reminders tolerate an \
             hour, and the watchdog has a tier to itself"
        );
    }

    #[tokio::test]
    async fn a_job_within_its_margin_is_not_stalled() {
        let health = health_with(&[("on-time", Some(Duration::ZERO), Duration::from_secs(5))]);

        assert_eq!(check_for_stalled_jobs(&health).await, 0);
    }

    #[tokio::test]
    async fn a_job_well_past_its_margin_is_stalled() {
        let health = health_with(&[(
            "stuck",
            Some(Duration::from_secs(3600)),
            Duration::from_secs(5),
        )]);

        assert_eq!(check_for_stalled_jobs(&health).await, 1);
    }

    #[tokio::test]
    async fn a_job_that_has_never_run_is_not_flagged() {
        let health = health_with(&[("never-run", None, Duration::from_secs(5))]);

        assert_eq!(
            check_for_stalled_jobs(&health).await,
            0,
            "never having run yet must not read the same as having stalled"
        );
    }

    #[tokio::test]
    async fn only_the_stalled_job_is_counted_not_every_job_present() {
        let health = health_with(&[
            (
                "stuck",
                Some(Duration::from_secs(3600)),
                Duration::from_secs(5),
            ),
            ("fine", Some(Duration::ZERO), Duration::from_secs(5)),
        ]);

        assert_eq!(check_for_stalled_jobs(&health).await, 1);
    }

    #[tokio::test]
    async fn a_misleading_wall_clock_timestamp_does_not_change_the_verdict() {
        // R4/R5 fix: a health entry can carry a `last_completed_at` that
        // looks perfectly fresh — exactly what a wall-clock jump would
        // produce — while the real, monotonic instant is genuinely stale.
        // The verdict must follow the instant, not the epoch field.
        let health = HashMap::from([(
            "stuck-but-looks-fresh",
            JobHealth {
                last_completed_at: Some(now_unix_seconds()),
                last_completed_instant: Some(Instant::now() - Duration::from_secs(3600)),
                errored_last_pass: 0,
                expected_interval: Duration::from_secs(5),
            },
        )]);
        let health = Arc::new(Mutex::new(health));

        assert_eq!(
            check_for_stalled_jobs(&health).await,
            1,
            "a fresh-looking last_completed_at must not mask a stale last_completed_instant"
        );
    }
}
