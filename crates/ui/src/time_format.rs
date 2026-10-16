//! Formats the server's `last_activity_at` timestamps (seconds since the
//! Unix epoch, as a string — see `server-game::persistence::now_iso`) as a
//! short relative string like "3m ago" for the games list.

#[cfg(target_arch = "wasm32")]
fn now_epoch_seconds() -> u64 {
    (js_sys::Date::now() / 1000.0) as u64
}

#[cfg(not(target_arch = "wasm32"))]
fn now_epoch_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

/// Falls back to the raw string if it isn't parseable, so an unexpected
/// server format degrades gracefully instead of panicking the UI.
pub fn format_relative_time(epoch_seconds: i64) -> String {
    let diff = now_epoch_seconds().saturating_sub(epoch_seconds.max(0) as u64);

    if diff < 10 {
        "just now".to_string()
    } else if diff < 60 {
        format!("{diff}s ago")
    } else if diff < 3_600 {
        format!("{}m ago", diff / 60)
    } else if diff < 86_400 {
        format!("{}h ago", diff / 3_600)
    } else if diff < 604_800 {
        format!("{}d ago", diff / 86_400)
    } else {
        format!("{}w ago", diff / 604_800)
    }
}

/// How long is left on the current turn before the seat gets auto-retired
/// (see `GameSession::apply_move_timeout` on the server), given when the
/// turn started and the game's move-time-limit, both in seconds since the
/// Unix epoch. The wording is `remaining_label`'s.
pub fn format_time_remaining(turn_started_at: i64, move_time_limit_seconds: u64) -> String {
    let deadline = turn_started_at.max(0) as u64 + move_time_limit_seconds;
    let now = now_epoch_seconds();
    if now >= deadline {
        return "overdue".to_string();
    }
    remaining_label(deadline - now)
}

/// The countdown for `remaining` seconds, per `docs/1.0` CLOCK-5 and CLOCK-6:
/// at most two adjacent units, truncated rather than rounded up, and `<1m`
/// for the last minute, because `0m` says the turn is lost and `1m` promises
/// time that may not exist. Days and hours above an hour, minutes below it.
fn remaining_label(remaining: u64) -> String {
    if remaining < 60 {
        "<1m left".to_string()
    } else if remaining < 3_600 {
        format!("{}m left", remaining / 60)
    } else {
        let days = remaining / 86_400;
        let hours = (remaining % 86_400) / 3_600;
        if days > 0 {
            format!("{days}d {hours}h left")
        } else {
            format!("{hours}h left")
        }
    }
}

/// Human-readable move time from microseconds. Bots are routinely
/// sub-millisecond, so this scales µs → ms → s → m·s → h·m as the magnitude
/// grows; a human's turn wall-clock (seconds resolution) lands in the s/m/h
/// forms.
pub fn format_move_time(elapsed_us: u64) -> String {
    if elapsed_us < 1_000 {
        format!("{elapsed_us}µs")
    } else if elapsed_us < 1_000_000 {
        format!("{}ms", elapsed_us / 1_000)
    } else {
        let secs = elapsed_us / 1_000_000;
        if secs < 60 {
            format!("{secs}s")
        } else if secs < 3_600 {
            format!("{}m {}s", secs / 60, secs % 60)
        } else {
            format!("{}h {}m", secs / 3_600, (secs % 3_600) / 60)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // CLOCK-5 and CLOCK-6, docs/1.0: two adjacent units at most, truncated,
    // and nothing that claims time the player may not have.

    #[test]
    fn shows_days_and_hours_above_a_day() {
        assert_eq!(
            remaining_label(2 * 86_400 + 4 * 3_600 + 59 * 60),
            "2d 4h left"
        );
    }

    #[test]
    fn shows_hours_only_under_a_day() {
        assert_eq!(remaining_label(4 * 3_600 + 59 * 60), "4h left");
    }

    #[test]
    fn exactly_one_hour_reads_as_an_hour() {
        assert_eq!(remaining_label(3_600), "1h left");
    }

    #[test]
    fn minutes_are_truncated_not_rounded_up() {
        assert_eq!(remaining_label(3_599), "59m left");
        assert_eq!(remaining_label(30 * 60 + 59), "30m left");
    }

    #[test]
    fn the_last_full_minute_still_reads_one_minute() {
        assert_eq!(remaining_label(60), "1m left");
    }

    #[test]
    fn under_a_minute_claims_neither_zero_nor_one() {
        // CLOCK-6: "0m left" says the turn is lost; "1m left" promises
        // seconds that may not exist.
        assert_eq!(remaining_label(59), "<1m left");
        assert_eq!(remaining_label(1), "<1m left");
    }

    #[test]
    fn a_turn_in_progress_reads_through_the_label() {
        // Well away from any boundary, since the clock is read twice.
        let started = (now_epoch_seconds() - (72 * 3_600 - 30 * 60 - 30)) as i64;
        assert_eq!(format_time_remaining(started, 72 * 3_600), "30m left");
    }

    #[test]
    fn reports_overdue_once_the_deadline_has_passed() {
        let started = (now_epoch_seconds() - 73 * 3_600) as i64;
        assert_eq!(format_time_remaining(started, 72 * 3_600), "overdue");
    }

    #[test]
    fn format_move_time_scales_by_magnitude() {
        assert_eq!(format_move_time(400), "400µs"); // sub-millisecond bot move
        assert_eq!(format_move_time(40_000), "40ms");
        assert_eq!(format_move_time(8_000_000), "8s"); // whole-second human turn
        assert_eq!(format_move_time(90_000_000), "1m 30s");
        assert_eq!(format_move_time(3_930_000_000), "1h 5m");
    }
}
