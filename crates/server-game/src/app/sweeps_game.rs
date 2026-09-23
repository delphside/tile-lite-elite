//! Sweeps that apply a **game rule** on a schedule: a seat running out of
//! time, and the reminder that precedes it. Owned by Application & Game
//! Architecture, because what they do is a game's life rather than the
//! service's housekeeping — turn expiry decides whose turn it is and
//! broadcasts the result (docs/3.7, #256).
//!
//! Retention and the daily size measurement live in `sweeps_capacity.rs`
//! and stay lazy — the owner's decision, 2026-09-22, defers them until
//! Capacity Planning's own schedules are ready.
//!
//! **The mechanism is this workstream's too** (#166), and `expire_overdue_turns`
//! and `send_move_time_reminders` are its first two customers (#400):
//! `scheduler::spawn_scheduler` runs them on a cadence now, not the
//! game-list handler. `expire_overdue_turn` (singular, below) is unrelated
//! and stays lazy — a handler that already knows which one game it cares
//! about checking that game alone is cheaper than waiting for the next pass.

use super::*;

/// Auto-retires any seat that has overrun its `move_time_limit_seconds`
/// (same effect as resigning). Runs on the scheduler's fast interval
/// (`scheduler::FAST_INTERVAL`) rather than from a handler — see this
/// module's doc comment — because this is the one deadline somebody is
/// watching expire. Persists and broadcasts every game it changes, and
/// returns how many of those saves or lookups failed, for R5's health
/// numbers; a failure is still logged at its own call site exactly as
/// before.
pub(crate) async fn expire_overdue_turns(state: &AppState) -> u64 {
    // Named `retired` rather than `finished` because retiring a seat is not
    // the same as ending the game: `apply_move_timeout` returns true whenever
    // it takes a seat, and `handle_seat_exit` only finishes the game once at
    // most one seat is still playing. With three or more, the others play on.
    let mut retired = Vec::new();
    let mut errored = 0u64;
    {
        let mut games = state.games.write().await;
        for game in games.values_mut() {
            if game.apply_move_timeout() {
                tracing::info!(game_id = %game.id, seat = game.current_seat, "seat auto-retired for exceeding the move time limit");
                if let Err(error) = persistence::save_game(&state.db, game).await {
                    tracing::error!(game_id = %game.id, %error, "failed to persist timeout retirement");
                    errored += 1;
                }
                retired.push(game.to_dto());
            }
        }
    }
    for dto in &mut retired {
        if let Err(error) = stats::attach_current_ratings(&state.db, dto).await {
            tracing::error!(game_id = %dto.id, %error, "failed to read current ratings after timeout retirement");
            errored += 1;
        }
    }
    // Always a no-op — a timeout never moves rating (see
    // `stats::settle_ratings`) — kept for consistency with every other
    // place a Finished game's DTO goes out.
    for dto in &mut retired {
        if let Err(error) = stats::attach_rating_deltas(&state.db, dto).await {
            tracing::error!(game_id = %dto.id, %error, "failed to read rating deltas after timeout retirement");
            errored += 1;
        }
    }
    // The same conditional every other exit path uses — see
    // `roster::force_resign_seat`, which retires a seat the same way and
    // documents the pattern. Announcing a finish for a game still being
    // played tells the remaining players it is over.
    for dto in retired {
        let event = if dto.status == api::GameStatus::Finished {
            GameEventDto::GameFinished { game: dto }
        } else {
            GameEventDto::StateUpdated { game: dto }
        };
        let _ = state.events.send(event);
    }
    errored
}

/// Move-time-limit fraction remaining at which a reminder email fires —
/// see `send_move_time_reminders`.
pub(crate) const REMINDER_REMAINING_FRACTION: u64 = 3;

/// Games with a same-day move-time-limit don't get reminders — a limit
/// that short doesn't leave enough runway for one to be useful.
pub(crate) const REMINDER_MIN_TIME_LIMIT_SECONDS: u64 = 24 * 60 * 60;

/// Runs on the scheduler's slow interval (`scheduler::SLOW_INTERVAL`) —
/// see this module's doc comment — since an hour's tolerance is ample for a
/// reminder. Checks every active game whose `move_time_limit_seconds`
/// exceeds a day, and emails the seat on turn once its remaining time
/// drops to a third of that limit (e.g. 24h remaining on the default 72h
/// limit). Fires at most once per turn, tracked via
/// `ParticipantState::reminder_sent_turn`, and only for claimed human
/// seats — engines never run out the clock in a way anyone needs telling
/// about, and an unclaimed seat has no one to email. Returns how many
/// persists or lookups failed on this pass, for R5's health numbers; a
/// failure is still logged at its own call site exactly as before.
pub(crate) async fn send_move_time_reminders(state: &AppState) -> u64 {
    struct Reminder {
        game_id: String,
        seat: u8,
        player_id: String,
        display_name: String,
        remaining_seconds: u64,
    }

    let mut reminders = Vec::new();
    let mut errored = 0u64;
    {
        let mut games = state.games.write().await;
        for game in games.values_mut() {
            if game.move_time_limit_seconds <= REMINDER_MIN_TIME_LIMIT_SECONDS {
                continue;
            }
            let Some(remaining) = game.seconds_remaining_on_turn() else {
                continue;
            };
            if remaining * REMINDER_REMAINING_FRACTION > game.move_time_limit_seconds {
                continue;
            }
            let seat = game.current_seat;
            let turn_number = game.turn_number;
            let Some(participant) = game.participants.get_mut(seat as usize) else {
                continue;
            };
            if participant.kind != api::SeatKind::Human
                || participant.reminder_sent_turn == Some(turn_number)
            {
                continue;
            }
            let Some(player_id) = participant.player_id.clone() else {
                continue;
            };
            participant.reminder_sent_turn = Some(turn_number);
            let display_name = participant.display_name.clone();

            if let Err(error) = persistence::save_game(&state.db, game).await {
                tracing::error!(game_id = %game.id, %error, "failed to persist move-time reminder flag");
                errored += 1;
            }
            reminders.push(Reminder {
                game_id: game.id.clone(),
                seat,
                player_id,
                display_name,
                remaining_seconds: remaining,
            });
        }
    }

    for reminder in reminders {
        let player = match persistence::get_player_by_id(&state.db, &reminder.player_id).await {
            Ok(Some(player)) => player,
            Ok(None) => continue,
            Err(error) => {
                tracing::error!(game_id = %reminder.game_id, seat = reminder.seat, %error, "failed to look up player for move-time reminder");
                errored += 1;
                continue;
            }
        };
        tracing::info!(game_id = %reminder.game_id, seat = reminder.seat, "move-time reminder sent");
        crate::email::send_move_time_reminder(
            &state.email,
            &player.email,
            &player.id,
            &reminder.display_name,
            &format_duration_days_hours(reminder.remaining_seconds),
            &state.public_base_url,
        )
        .await;
    }
    errored
}

/// "1 day 4 hours" / "1 day" / "4 hours" style label for the reminder
/// email's body — coarser than the UI's `format_time_remaining` (spelled
/// out, not `d`/`h` shorthand) since this reads as a sentence.
pub(crate) fn format_duration_days_hours(total_seconds: u64) -> String {
    let days = total_seconds / 86_400;
    let hours = (total_seconds % 86_400) / 3_600;
    let day_part = (days > 0).then(|| format!("{days} day{}", if days == 1 { "" } else { "s" }));
    let hour_part =
        (hours > 0).then(|| format!("{hours} hour{}", if hours == 1 { "" } else { "s" }));
    match (day_part, hour_part) {
        (Some(d), Some(h)) => format!("{d} {h}"),
        (Some(d), None) => d,
        (None, Some(h)) => h,
        (None, None) => "less than an hour".to_string(),
    }
}

/// Same as `expire_overdue_turns` but scoped to one game — cheaper for
/// handlers that already know which game they care about.
pub(crate) async fn expire_overdue_turn(state: &AppState, game_id: &str) {
    let mut finished = {
        let mut games = state.games.write().await;
        let Some(game) = games.get_mut(game_id) else {
            return;
        };
        if !game.apply_move_timeout() {
            return;
        }
        tracing::info!(
            game_id,
            seat = game.current_seat,
            "seat auto-retired for exceeding the move time limit"
        );
        if let Err(error) = persistence::save_game(&state.db, game).await {
            tracing::error!(game_id, %error, "failed to persist timeout retirement");
        }
        game.to_dto()
    };
    if let Err(error) = stats::attach_current_ratings(&state.db, &mut finished).await {
        tracing::error!(game_id, %error, "failed to read current ratings after timeout retirement");
    }
    // Always a no-op — a timeout never moves rating (see
    // `stats::settle_ratings`) — kept for consistency with every other
    // place a Finished game's DTO goes out.
    if let Err(error) = stats::attach_rating_deltas(&state.db, &mut finished).await {
        tracing::error!(game_id, %error, "failed to read rating deltas after timeout retirement");
    }
    let _ = state
        .events
        .send(GameEventDto::GameFinished { game: finished });
}

// ========== Admin Handlers ==========
//

#[cfg(test)]
mod tests {
    /// The two sweeps the owner deferred (#400) still run from one place, in
    /// one order, because nothing schedules them yet. `expire_overdue_turns`
    /// and `send_move_time_reminders` left this list when the scheduler
    /// became their trigger — see `scheduler::spawn_scheduler` — which is
    /// what shrank this from four names to two; it is not a relaxation of
    /// the rule, only of its scope.
    ///
    /// This reads the handler's source rather than its behaviour, which is
    /// unusual and deliberate: both remaining sweeps are invisible when they
    /// do not happen. A missing day in the size series is — by that table's
    /// own schema comment — "quiet, not broken". There is nothing to
    /// observe, so the thing worth guarding is the call site itself.
    #[test]
    fn the_two_lazy_sweeps_still_run_in_order_from_one_place() {
        let games = include_str!("games.rs");
        let order: Vec<&str> = [
            "expire_old_terminal_games(&state)",
            "record_database_size(&state)",
        ]
        .into_iter()
        .collect();

        let mut positions = Vec::new();
        for name in &order {
            let at = games
                .find(name)
                .unwrap_or_else(|| panic!("{name} is no longer called from games.rs"));
            positions.push(at);
        }

        let mut sorted = positions.clone();
        sorted.sort_unstable();
        assert_eq!(
            positions, sorted,
            "the sweeps are called in a different order from the one they were split in"
        );
    }
}
