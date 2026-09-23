//! Which jobs the scheduler (`scheduler.rs`) actually runs, kept apart from
//! the engine on purpose: a workstream adding a job edits this file, never
//! `Job`, `run_once` or `spawn`, so growing the list carries no risk of
//! changing behaviour those already have tests for.

use super::AppState;
use super::scheduler::{FAST_INTERVAL, Job, SLOW_INTERVAL, spawn};

/// Wires the scheduler's first two customers — `#400`'s deliveries table
/// names four; `#87`'s message-arrived notification and RET-3's countdown
/// are new game behaviour and stay off this until built and reviewed. These
/// two already exist and already run (lazily, from `list_games`); this
/// moves *when* they run, not what they do.
pub fn spawn_scheduler(state: AppState) {
    let fast = vec![Job::new(
        "expire_overdue_turns",
        state.clone(),
        |state| async move { super::sweeps_game::expire_overdue_turns(&state).await },
    )];
    spawn(fast, FAST_INTERVAL, state.scheduler_health.clone());

    let slow = vec![Job::new(
        "send_move_time_reminders",
        state.clone(),
        |state| async move { super::sweeps_game::send_move_time_reminders(&state).await },
    )];
    spawn(slow, SLOW_INTERVAL, state.scheduler_health.clone());
}
