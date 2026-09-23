//! Which jobs the scheduler (`scheduler.rs`) actually runs, kept apart from
//! the engine on purpose: a workstream adding a job edits this file, never
//! `Job`, `run_once` or `spawn`, so growing the list carries no risk of
//! changing behaviour those already have tests for.

use super::AppState;
use super::scheduler::{FAST_INTERVAL, Job, SLOW_INTERVAL, SchedulerHealth, spawn};

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
/// **`check_for_stalled_jobs` runs on `FAST`, watching `SLOW`.** Either
/// tier can only reliably watch the *other* one — `run_once` runs a
/// tier's jobs in sequence, so a hang earlier in the same tier's list
/// would freeze the watchdog too. `FAST` is the choice because turn
/// expiry (the job that most needs prompt detection) is the one a
/// same-tier watchdog could never reliably cover anyway, so putting the
/// watchdog here at least gets `SLOW`'s hang risk onto active alerting;
/// `FAST`'s own risk stays exactly where it was, passive-only.
pub fn spawn_scheduler(state: AppState) {
    let fast = vec![
        Job::new(
            "expire_overdue_turns",
            FAST_INTERVAL,
            state.clone(),
            |state| async move { super::sweeps_game::expire_overdue_turns(&state).await },
        ),
        Job::new(
            "check_for_stalled_jobs",
            FAST_INTERVAL,
            state.clone(),
            |state| async move { check_for_stalled_jobs(&state.scheduler_health).await },
        ),
    ];
    spawn(fast, FAST_INTERVAL, state.scheduler_health.clone());

    let slow = vec![Job::new(
        "send_move_time_reminders",
        SLOW_INTERVAL,
        state.clone(),
        |state| async move { super::sweeps_game::send_move_time_reminders(&state).await },
    )];
    spawn(slow, SLOW_INTERVAL, state.scheduler_health.clone());
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
