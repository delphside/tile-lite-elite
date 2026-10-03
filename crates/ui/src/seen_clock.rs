//! How long the unread messages have actually been in front of somebody.
//!
//! The unread indicator used to clear the moment a message arrived while the
//! game was open — "watching the panel counts as reading it". On a phone the
//! chat panel is often scrolled off screen entirely, and a tab can be in the
//! background, so that cleared the mark for messages nobody had seen. The
//! watermark meant *arrived*, and it needs to mean *seen*.
//!
//! This is the part with logic in it, kept free of the browser so it can be
//! tested without one. It knows nothing about observers or timers: something
//! else tells it when the messages became visible, when they stopped being
//! visible, and when a new message arrived; it answers whether they have been
//! watched for long enough.

/// How long the messages must be visible before they count as read.
pub const SEEN_AFTER_MS: i64 = 10_000;

/// Total time the chat has been in front of somebody, across however many
/// interruptions — an accumulator, not a countdown.
///
/// Suspending keeps what has been earned rather than discarding it: somebody
/// who looks for six seconds, switches tab, and comes back needs four more, not
/// ten. That is the whole reason this holds state instead of being a timeout.
///
/// **It never restarts.** Each message records this clock's reading when it
/// arrived, and is seen once the clock has advanced `SEEN_AFTER_MS` beyond
/// that. One accumulator serves every message, and each gets its own ten
/// seconds without needing a timer of its own.
///
/// The earlier design restarted the whole clock on every arrival, which meant a
/// brisk exchange kept everything unread while somebody was plainly reading it
/// — a new message held back the ones already on screen. Per-message arrivals
/// cure that: a new message delays only itself.
///
/// Seen-ness stays monotonic in arrival order, because a message that arrived
/// earlier has a smaller reading to beat. That is what lets a single watermark
/// — "everything up to here is read" — still express the state exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SeenClock {
    /// Watching time banked from earlier stretches.
    banked_ms: i64,
    /// When the current stretch began, if the messages are visible now.
    visible_since: Option<i64>,
}

impl SeenClock {
    /// Nothing watched yet.
    pub fn new() -> Self {
        Self::default()
    }

    /// The messages became visible. Ignored if they already were, so a repeated
    /// notification — two observers, or a re-render — cannot restart the
    /// stretch and quietly lose the time already earned.
    pub fn became_visible(&mut self, now_ms: i64) {
        if self.visible_since.is_none() {
            self.visible_since = Some(now_ms);
        }
    }

    /// The messages stopped being visible: scrolled away, covered, or the tab
    /// went to the background. Banks the current stretch.
    pub fn became_hidden(&mut self, now_ms: i64) {
        if let Some(since) = self.visible_since.take() {
            self.banked_ms += (now_ms - since).max(0);
        }
    }

    /// Total visible time, including the stretch in progress. Messages are
    /// measured against this rather than against the wall clock.
    pub fn visible_ms(&self, now_ms: i64) -> i64 {
        let running = self
            .visible_since
            .map(|since| (now_ms - since).max(0))
            .unwrap_or(0);
        self.banked_ms + running
    }

    /// Has a message that arrived at clock reading `arrived_at` been watched
    /// long enough to count as read?
    pub fn is_seen(&self, arrived_at: i64, now_ms: i64) -> bool {
        self.visible_ms(now_ms) - arrived_at >= SEEN_AFTER_MS
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The plain case: ten unbroken seconds.
    #[test]
    fn ten_seconds_of_watching_counts_as_seen() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        assert!(!clock.is_seen(0, 9_999), "not yet, a millisecond short");
        assert!(clock.is_seen(0, 10_000));
    }

    /// Nothing counts while the messages are not on screen.
    ///
    /// This is the case the old behaviour got wrong: a message arriving into a
    /// panel scrolled off the bottom of a phone was marked read immediately.
    #[test]
    fn time_while_hidden_does_not_count() {
        let clock = SeenClock::new();
        assert_eq!(clock.visible_ms(60_000), 0);
        assert!(!clock.is_seen(0, 60_000));
    }

    /// Suspending banks the time rather than discarding it, and resuming
    /// carries on — six seconds then four is seen, not six then ten.
    #[test]
    fn watching_resumes_where_it_left_off() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_hidden(6_000);
        assert_eq!(clock.visible_ms(30_000), 6_000, "the gap must not accrue");
        assert!(!clock.is_seen(0, 30_000));

        clock.became_visible(30_000);
        assert!(!clock.is_seen(0, 33_999), "six banked plus not quite four");
        assert!(clock.is_seen(0, 34_000), "six banked plus four is ten");
    }

    /// Several interruptions add up.
    #[test]
    fn many_short_looks_add_up() {
        let mut clock = SeenClock::new();
        for stretch in 0..5 {
            let start = stretch * 100_000;
            clock.became_visible(start);
            clock.became_hidden(start + 2_000);
        }
        assert_eq!(clock.visible_ms(500_000), 10_000);
        assert!(clock.is_seen(0, 500_000));
    }

    /// A repeated "visible" must not restart the stretch in progress.
    ///
    /// Two sources report visibility — the observer and the tab's own
    /// visibility — and a re-render can fire either again. If that reset
    /// `visible_since`, a tab left open would never accumulate anything and the
    /// indicator would never clear, which reads as the feature being broken
    /// rather than as double-notification.
    #[test]
    fn being_told_it_is_visible_twice_does_not_lose_the_stretch() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_visible(5_000);
        clock.became_visible(9_000);
        assert!(
            clock.is_seen(0, 10_000),
            "the stretch began at 0, not at 9,000"
        );
    }

    /// Each message gets its own ten seconds, measured from its own arrival.
    #[test]
    fn every_message_is_seen_on_its_own_schedule() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);

        // One arrives immediately, the next four seconds later.
        let first = clock.visible_ms(0);
        let second = clock.visible_ms(4_000);

        assert!(clock.is_seen(first, 10_000), "the first is seen at ten");
        assert!(
            !clock.is_seen(second, 10_000),
            "the second has had only six"
        );
        assert!(clock.is_seen(second, 14_000), "and is seen at fourteen");
    }

    /// A new message must not hold back one already on screen.
    ///
    /// The failure this replaces: the clock restarted on every arrival, so a
    /// brisk exchange kept everything unread while somebody was plainly reading
    /// it. Nine seconds of watching were discarded by a message that had
    /// nothing to do with the one being read.
    #[test]
    fn a_later_message_does_not_delay_an_earlier_one() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        let first = clock.visible_ms(0);

        // Something arrives at nine seconds — under the old design this reset
        // the count and the first message stayed unread indefinitely.
        let second = clock.visible_ms(9_000);

        assert!(clock.is_seen(first, 10_000), "the first still lands at ten");
        assert!(
            !clock.is_seen(second, 10_000),
            "the newcomer has had one second"
        );
        assert!(clock.is_seen(second, 19_000));
    }

    /// Time while hidden counts for no message, whenever it arrived.
    #[test]
    fn a_message_arriving_while_hidden_ages_only_once_seen() {
        let mut clock = SeenClock::new();
        clock.became_visible(0);
        clock.became_hidden(2_000);

        // Arrives during the gap: the clock is not moving, so it is stamped
        // with the two seconds banked so far.
        let arrived = clock.visible_ms(50_000);
        assert_eq!(arrived, 2_000, "the gap must not accrue");

        clock.became_visible(60_000);
        assert!(
            !clock.is_seen(arrived, 69_999),
            "needs ten *visible* seconds"
        );
        assert!(clock.is_seen(arrived, 70_000));
    }

    /// A clock going backwards must not bank negative time.
    ///
    /// `performance.now()` is monotonic, but this takes whatever it is given,
    /// and negative banked time would make the indicator clear early — the
    /// exact failure being fixed.
    #[test]
    fn time_going_backwards_never_subtracts() {
        let mut clock = SeenClock::new();
        clock.became_visible(10_000);
        clock.became_hidden(5_000);
        assert_eq!(clock.visible_ms(10_000), 0);
    }
}
