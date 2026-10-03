//! Sweeps that keep the **service** within its limits rather than applying a
//! game rule: removing finished games, and recording what the database holds.
//! Owned by Capacity Planning (docs/3.7, #256).
//!
//! Turn expiry and move-time reminders live in `sweeps_game.rs`. They are
//! separated because they are different work with different owners, not
//! because they run differently — all of them still run from the same call
//! site, in the same order, until #166 builds a scheduler.

use super::*;

/// Records what the database holds, once a day.
///
/// Hung off the same lazy path as the other sweeps rather than given a
/// scheduler: `list_games` runs whenever anybody uses the service, and the
/// day's primary key in `database_size_history` makes the once-a-day part
/// self-enforcing — the insert is `or ignore`, so a second caller on the same
/// day writes nothing rather than racing.
///
/// **A service nobody uses records nothing.** That is the accepted cost of
/// having no scheduler, and it is fine — a day with no requests has no growth
/// to explain — but it means a gap in the series reads "quiet", never "broken".
/// Anything that later compares days (#89) has to know that.
///
/// Failure is logged and swallowed. This is measurement; it must never be the
/// reason somebody cannot list their games.
pub(crate) async fn record_database_size(state: &AppState) {
    let games_in_memory = state.games.read().await.len() as i64;
    match persistence::record_database_size(&state.db, games_in_memory).await {
        Ok(true) => tracing::info!(games_in_memory, "recorded the day's database size"),
        Ok(false) => {}
        Err(error) => tracing::error!(%error, "failed to record the database size"),
    }
}

/// Permanently deletes any game that has been terminal — `Finished` *or*
/// `Aborted` — for more than 7 days: chat, moves, participants, invitations,
/// and rating history all go with it (`persistence::delete_game` is the same
/// cascading delete admin's "delete game" uses). No background scheduler:
/// called lazily from `list_games`, same as `expire_overdue_turns`.
///
/// Aborted games are included because they're just as dead as finished ones
/// and nothing else ever collects them — see
/// `persistence::list_terminal_game_ids_older_than`.
///
/// Concurrency: two callers racing into this (e.g. two participants both
/// hitting `GET /games` at once) can't corrupt anything or double-fire a
/// broadcast — (1) the write lock is held across the *entire* sweep,
/// including the awaited deletes, exactly like `expire_overdue_turns`
/// already does, so a second concurrent caller simply waits for the first
/// sweep to finish rather than running alongside it; (2) every step is
/// independently idempotent as a second line of defense regardless of
/// locking — a SQL `delete ... where id = ?` on an already-gone row affects
/// zero rows, and removing an already-removed key from the map is a no-op.
pub(crate) async fn expire_old_terminal_games(state: &AppState) {
    let now = now_unix_seconds();
    let cutoff = now - 7 * 24 * 60 * 60;
    let stale_ids = match persistence::list_terminal_game_ids_older_than(&state.db, cutoff).await {
        Ok(ids) => ids,
        Err(error) => {
            tracing::error!(%error, "failed to query terminal games for expiry");
            return;
        }
    };
    if stale_ids.is_empty() {
        return;
    }

    let mut games = state.games.write().await;
    for game_id in stale_ids {
        match persistence::delete_game(&state.db, &game_id).await {
            Ok(_) => {
                games.remove(&game_id);
                tracing::info!(game_id, "terminal game auto-deleted after 7 days");
            }
            Err(error) => {
                tracing::error!(game_id, %error, "failed to auto-delete expired game");
            }
        }
    }
}
