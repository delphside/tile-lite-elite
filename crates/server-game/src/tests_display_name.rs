//! Regression tests for the display-name fold — #301.
//!
//! `fold_display_name` backs login, the registration "already taken" check,
//! the update-details check and the unique index. All four agree only because
//! they call it, so its behaviour is a contract rather than an implementation
//! detail — and it had **no tests at all** before this file.
//!
//! **These pin today's fold, which is NFC then lowercase.** R6 of #301
//! changes it to NFKC, and that is deliberate rather than accidental: the
//! tests marked `R6` below are the ones that must change when it lands, and
//! they fail loudly rather than silently accepting either fold. A test that
//! passes under both would not tell you the change had happened.
//!
//! What is *not* here, because it belongs to a later phase: R4's structural
//! rules (length, permitted characters) are not implemented yet, so there is
//! nothing to regress. The test approach on #301 lists them as owed.

use crate::persistence::fold_display_name;

// --------------------------------------------------------------------------
// The invariants that hold under any fold, and must never stop holding.
// These are the regression net: they are the reason a name that can be
// created can also be used (R7) and found (R11).
// --------------------------------------------------------------------------

#[test]
fn folding_is_idempotent() {
    // Login folds an already-folded stored value on one side and raw input on
    // the other. If folding twice differed from folding once, a name could be
    // created and then never matched.
    for name in ["Alice", "JOSÉ", "  Bob  ", "ﬁnn", "Ｊｏｈｎ", "o\u{0308}dd"] {
        let once = fold_display_name(name);
        assert_eq!(
            fold_display_name(&once),
            once,
            "folding {name:?} twice differs from folding it once"
        );
    }
}

#[test]
fn case_does_not_survive_the_fold() {
    // R7: a name that can be created can be used, whatever case it is typed in.
    assert_eq!(fold_display_name("Alice"), fold_display_name("ALICE"));
    assert_eq!(fold_display_name("alice"), fold_display_name("AlIcE"));
}

#[test]
fn case_folding_is_unicode_aware_not_ascii_only() {
    // The reason the fold exists in Rust rather than in SQL: SQLite's
    // `lower()` and `NOCASE` fold ASCII A-Z only, so `JOSÉ` and `josé` would
    // be two accounts rendering almost identically.
    assert_eq!(fold_display_name("JOSÉ"), fold_display_name("josé"));
    assert_eq!(fold_display_name("ÅNGSTRÖM"), fold_display_name("ångström"));
}

#[test]
fn composed_and_decomposed_accents_are_one_name() {
    // `é` as one code point, and `e` + combining acute. They render
    // identically, so they must not be two accounts.
    let composed = "Jos\u{00e9}";
    let decomposed = "Jose\u{0301}";
    assert_ne!(
        composed, decomposed,
        "the inputs must differ, or this proves nothing"
    );
    assert_eq!(fold_display_name(composed), fold_display_name(decomposed));
}

#[test]
fn distinct_names_stay_distinct() {
    // The fold must not collapse names that are genuinely different, or one
    // player blocks another's registration for no visible reason.
    let names = [
        "alice", "alicia", "bob", "josé", "jose", "o'brien", "obrien",
    ];
    for (i, a) in names.iter().enumerate() {
        for b in &names[i + 1..] {
            assert_ne!(
                fold_display_name(a),
                fold_display_name(b),
                "{a:?} and {b:?} fold together"
            );
        }
    }
}

// --------------------------------------------------------------------------
// R6 — these pin the CURRENT fold and must change when NFC becomes NFKC.
// They are written to fail on the change rather than to tolerate it.
// --------------------------------------------------------------------------

#[test]
fn r6_compatibility_forms_are_not_yet_folded_together() {
    // Fullwidth `Ｊｏｈｎ` and ASCII `john` are one name under NFKC and two
    // under NFC. Today they are two.
    //
    // **When R6 lands this assertion inverts**: change `assert_ne` to
    // `assert_eq` and rename the test. It failing is the signal that the fold
    // changed, which is the point of pinning it.
    assert_ne!(
        fold_display_name("Ｊｏｈｎ"),
        fold_display_name("john"),
        "the fold now unifies compatibility forms — R6 has landed, update this test"
    );
}

#[test]
fn r6_ligatures_are_not_yet_folded_together() {
    // `ﬁnn` with the fi ligature against `finn`. NFKC decomposes the
    // ligature; NFC does not.
    assert_ne!(
        fold_display_name("ﬁnn"),
        fold_display_name("finn"),
        "the fold now decomposes ligatures — R6 has landed, update this test"
    );
}

// --------------------------------------------------------------------------
// What the fold does NOT do, recorded so the boundary is visible.
// --------------------------------------------------------------------------

#[test]
fn r6_the_fold_does_not_map_or_trim() {
    // R3 maps a name before validating it — trim, non-ASCII spaces to ASCII,
    // interior runs collapsed. That is a separate step and is not implemented,
    // so folding alone leaves whitespace exactly as given. Recorded so nobody
    // assumes the fold already does it.
    assert_eq!(fold_display_name("  bob  "), "  bob  ");

    // **This second assertion changes under R6, and the overlap is worth
    // knowing about.** NFKC maps U+00A0 to an ASCII space, so switching the
    // fold does part of R3's mapping as a side effect. R3 still owes the trim
    // and the run-collapsing, and must not be considered done because the
    // fold changed.
    assert_eq!(
        fold_display_name("john\u{00a0}smith"),
        "john\u{00a0}smith",
        "the fold now maps non-ASCII spaces — R6 has landed, and it does part \
         of R3's mapping for free; R3 still owes the trim and the collapse"
    );
}
