//! The plural of a greylisted word must be greylisted too.
//!
//! The bot played JISMS while JISM was on the list (2026-08-29). That is this
//! project's own stated defect in reverse: `greylist-stems.txt` exists because
//! rustrict flags NEGROES and not NEGRO, and nothing was checking the other
//! direction — the base caught, the plural loose.
//!
//! A regression test rather than a completeness one. Ninety-three plurals were
//! added at once, and this asserts a sample of them stays added, including the
//! two kinds: one whose base is unambiguous, and one whose base is a substring
//! catch kept for consistency.

use rules_shared::wordlists::is_avoided_by_engines;

#[test]
fn a_plural_of_a_greylisted_word_is_itself_avoided() {
    for word in [
        "JISM", "JISMS", "FANNY", "FANNIES", "SPICK", "SPICKS", "POOF", "POOVES",
    ] {
        assert!(
            is_avoided_by_engines(word),
            "{word} should be avoided by engines"
        );
    }
}

#[test]
fn the_kept_for_consistency_group_is_avoided_too() {
    // Their bases look like substring catches — MOMMY, DEBUGGER — and are
    // greylisted anyway. While that is true, the plural being playable would
    // be the list disagreeing with itself. See #116.
    for word in ["MOMMIES", "DADDIES", "DEBUGGERS", "ANNALS"] {
        assert!(
            is_avoided_by_engines(word),
            "{word} should be avoided by engines"
        );
    }
}

#[test]
fn ordinary_words_are_still_playable() {
    // The greylist removes under 1% of SOWPODS. This is the guard against a
    // regeneration that quietly removes a great deal more.
    for word in ["HOUSE", "TABLE", "QUARTZ", "PLAYER", "LETTER"] {
        assert!(!is_avoided_by_engines(word), "{word} should be playable");
    }
}
