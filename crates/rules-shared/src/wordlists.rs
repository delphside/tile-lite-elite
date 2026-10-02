//! Two lists with different subjects: words nobody may play, and words no
//! engine will choose.
//!
//! See `wordlists/README.md` for why they exist, why the first is deliberately
//! narrow, and where the contents should come from. This module is only the
//! mechanism — parsing, and matching whole words exactly.

use std::collections::HashSet;

use crate::model::Alphabet;

/// The longest word any board can hold, and so the longest worth importing.
///
/// Counted in characters rather than tiles, which is a simplification for
/// Spanish: a 16-character word using a CH/LL/RR digraph would occupy 15
/// squares and is dropped anyway. That is the behaviour the committed lists
/// were built with, and no such word survives in the upstream data, so this
/// records the existing line rather than moving it.
const MAX_WORD_LENGTH: usize = 15;

/// Shorter than this cannot be played at all.
const MIN_WORD_LENGTH: usize = 2;

/// Puts an imported word list into the exact **form** the committed files hold.
///
/// This is the single definition of what a word list must look like, applied
/// where a list is imported *and* asserted where one is committed — see
/// `every_word_list_is_a_fixed_point_of_the_normaliser` in `dictionary.rs`.
/// Having one function on both sides is the point: a second copy of these rules
/// would drift, and the drift would be silent.
///
/// In order:
///
/// 1. **Uppercase.** The board holds uppercase graphemes, so the dictionary
///    must. This also handles German `ß`, which Unicode uppercases to `SS` —
///    exactly right here, because German sets have no `ß` tile and such words
///    are physically played as two `S` tiles. No special case needed.
/// 2. **Inside the alphabet.** Drops any word using a character this edition
///    cannot write, which is why an `Alphabet` is required rather than assumed:
///    Spanish files `Ñ` and has no `K` or `W`, German adds `Ä Ö Ü`. Taking the
///    real alphabet from `VariantRules` means this filter cannot disagree with
///    what the engine believes the letters are.
/// 3. **Playable length**, 2 to 15.
/// 4. **Sorted and deduped in byte order.** Byte order is code-point order for
///    UTF-8, which is the order the prefix cursor's binary search assumes. A
///    locale-aware sort is *not* equivalent: German collation files `Ä` beside
///    `A`, which would break lookups on the two non-ASCII lists while leaving
///    the two ASCII ones looking perfect.
///
/// **Deliberately does not remove denied words.** That is `remove_denied`, kept
/// separate and applied as its own step so the first deviation of a list from
/// its upstream source is a commit of its own, with the diff as the record of
/// what was taken out and when. Folding it in here would make the committed
/// file "source minus denied" from the very first commit, and nothing would
/// show the moment it stopped being the source. Form and content are also
/// different questions, and separating them means a failure says which one
/// broke.
///
/// Normalising here, once, rather than at every startup is the same argument
/// commit `25e9e09` (app 0.4.12) made when it stopped construction re-sorting a
/// 267,000-line
/// file in every process to fix two defective bytes.
pub fn normalise(text: &str, alphabet: &Alphabet) -> String {
    let writable: HashSet<char> = alphabet.chars().collect();

    let mut words: Vec<String> = text
        .lines()
        .map(|line| line.trim().to_uppercase())
        .filter(|word| {
            let length = word.chars().count();
            (MIN_WORD_LENGTH..=MAX_WORD_LENGTH).contains(&length)
                && word.chars().all(|c| writable.contains(&c))
        })
        .collect();

    words.sort_unstable();
    words.dedup();

    // Trailing newline, so the output is a well-formed text file and the
    // committed lists are fixed points of this function rather than differing
    // from it by one invisible byte.
    let mut out = words.join("\n");
    out.push('\n');
    out
}

/// Removed from every dictionary: invalid for everyone, human and engine.
const DENYLIST_FILE: &str = include_str!("wordlists/denylist.txt");

/// Left in the dictionaries, so a person may play them; never chosen by an
/// engine.
const GREYLIST_FILE: &str = include_str!("wordlists/greylist.txt");

/// One word per line, uppercase; `#` comments and blank lines ignored.
///
/// Normalising here rather than at every comparison means a list can be pasted
/// in whatever case it arrived in and still match.
fn parse(text: &str) -> HashSet<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|word| word.to_uppercase())
        .collect()
}

/// The words removed from every dictionary.
pub fn denylist() -> &'static HashSet<String> {
    static DENYLIST: std::sync::OnceLock<HashSet<String>> = std::sync::OnceLock::new();
    DENYLIST.get_or_init(|| parse(DENYLIST_FILE))
}

/// The words an engine will not choose.
pub fn greylist() -> &'static HashSet<String> {
    static GREYLIST: std::sync::OnceLock<HashSet<String>> = std::sync::OnceLock::new();
    GREYLIST.get_or_init(|| parse(GREYLIST_FILE))
}

/// Both lookups take the word exactly as given, with no allocation.
///
/// Normalising is the *entries'* job, done once in `parse` when the list is
/// first read — uppercasing the query instead would allocate a `String` per
/// call, and the engine calls this for the main word and every cross word of
/// every legal move it considers. That is thousands of allocations per bot
/// move, on the hot path of an operation already known to be slow.
///
/// The contract that makes it safe: every word the rules form is uppercase by
/// construction, because the board holds `Grapheme`s from the edition's
/// alphabet and those are uppercase. `debug_assert` states it so a caller that
/// breaks it fails a test rather than silently matching nothing — a safety
/// check that fails *open* is worse than one that is merely slow.
fn contains(list: &HashSet<String>, word: &str) -> bool {
    debug_assert_eq!(
        word,
        word.trim().to_uppercase(),
        "word lists are looked up without normalising, so callers must pass an \
         uppercase, trimmed word — see the note on `contains`"
    );
    // An empty list can never match, so it is worth saying so before hashing
    // the word at all — the denylist still ships empty, and it is consulted for
    // every word of every move the engine considers.
    !list.is_empty() && list.contains(word)
}

/// Is this word removed from the dictionaries?
///
/// **Whole word, exactly.** Never a substring test: filtering a word list for
/// anything *containing* a listed word removes `SCUNTHORPE`, `ASSASSIN` and
/// `BASEMENT`. That is the classic way this goes wrong, it goes wrong silently,
/// and there is a test below holding the line.
pub fn is_denied(word: &str) -> bool {
    contains(denylist(), word)
}

/// Should an engine decline to play this word?
///
/// Denied words are gone from the dictionaries already, so an engine cannot
/// enumerate them — but this includes them anyway rather than relying on that,
/// so an engine reading a dictionary from somewhere else still behaves.
pub fn is_avoided_by_engines(word: &str) -> bool {
    contains(greylist(), word) || contains(denylist(), word)
}

/// Removes the denied words from a word list, keeping everything else exactly
/// as it was — same order, same line endings.
///
/// An **import step**, not a runtime filter: run by the importer, its result
/// committed, and the diff is the record of what was removed. Deliberately kept
/// out of `normalise` so that removal is a commit of its own rather than
/// something a list has silently had done to it since before its first commit
/// — see the note there.
///
/// Every committed list is checked against the denylist by
/// `no_committed_word_list_holds_a_denied_word`, so a denylist that grows
/// without the lists being regenerated fails the build rather than quietly
/// leaving the words in play.
pub fn remove_denied(word_list: &str) -> String {
    if denylist().is_empty() {
        return word_list.to_string();
    }
    word_list
        .lines()
        .filter(|line| !is_denied(line))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The trap this whole module has to avoid.
    ///
    /// Every one of these contains a shorter word that a denylist could
    /// plausibly hold, and every one is an ordinary English word somebody would
    /// be furious to have refused. Written against `parse` directly so it holds
    /// whatever the committed lists happen to contain.
    #[test]
    fn matching_is_whole_word_never_substring() {
        let list = parse("CUNT\nASS\nNIT");
        for innocent in [
            "SCUNTHORPE",
            "ASSASSIN",
            "BASEMENT",
            "ASSET",
            "CLASSIC",
            "KNITTING",
            "UNITE",
        ] {
            assert!(
                !list.contains(innocent),
                "{innocent} is an ordinary word and must never be caught"
            );
        }
        assert!(list.contains("ASS"), "the exact word is still matched");
    }

    /// Case and surrounding space do not matter on either side.
    #[test]
    fn comparison_is_normalised() {
        let list = parse("  wop \n\n# a comment\nHONKY\n");
        assert_eq!(list.len(), 2, "comments and blanks are not words");
        assert!(list.contains("WOP"), "a lowercase entry is uppercased");
        assert!(list.contains("HONKY"));
    }

    /// Filtering keeps every word that is not listed, and drops the ones that
    /// are — including the last line, which a naive split loses.
    #[test]
    fn filtering_removes_only_the_listed_words() {
        let words = "ASSASSIN\nHONKY\nBASEMENT\nSCUNTHORPE";
        let denied = parse("HONKY");
        let kept: Vec<&str> = words
            .lines()
            .filter(|line| !denied.contains(&line.to_uppercase()))
            .collect();
        assert_eq!(kept, vec!["ASSASSIN", "BASEMENT", "SCUNTHORPE"]);
    }

    /// What actually ships: a populated greylist and an empty denylist.
    ///
    /// That combination is deliberate rather than half-finished. What an engine
    /// will never play is the *union* of the two lists, so a full greylist
    /// alone already stops a bot playing anything offensive; the denylist only
    /// decides what a *person* may play, and taking words away from people is
    /// the half that needs somebody's judgement. Filling the greylist first is
    /// therefore the whole protection at none of the risk, and this pins it so
    /// an empty greylist cannot return unnoticed.
    #[test]
    fn the_greylist_ships_populated_and_the_denylist_empty() {
        assert!(
            denylist().is_empty(),
            "the denylist is still to be curated — see wordlists/README.md"
        );
        assert!(
            greylist().len() > 2_000,
            "the greylist is generated and should hold ~2,500 words, found {}",
            greylist().len()
        );

        // An empty denylist must be a no-op rather than an accidental filter.
        let words = "ASSASSIN\nBASEMENT\nSCUNTHORPE";
        assert_eq!(remove_denied(words), words);
    }

    /// The generator's judgement, pinned where a person can see it.
    ///
    /// These are the accidents that a stem file makes easy: `MONG*` catching
    /// MONGOOSE, `SCAT*` catching SCATTER, `GYP*` catching GYPSUM, `ABO*`
    /// catching ABOARD. Each is an ordinary word, and each was a real candidate
    /// during drafting — the exclusions and exact-match entries in
    /// `greylist-stems.txt` exist because of them. If somebody later loosens a
    /// stem, this says so.
    ///
    /// The words below are only ever *greyed*, never denied, so being wrong
    /// here costs the bot some vocabulary rather than costing a person a move.
    /// It is still worth holding: a bot that will not play BUTTERFLY is a bug.
    #[test]
    fn stem_expansion_does_not_catch_ordinary_words() {
        for innocent in [
            "ABOARD",
            "ABODE",
            "ABOUT",
            "MONGOOSE",
            "MONGER",
            "MONGREL",
            "SCATTER",
            "SCATHE",
            "GYPSUM",
            "GYPSOPHILA",
            "WOGGLE",
            "DAGOBA",
            "NEGRONI",
            "WELSH",
            "ASSASSIN",
            "BASEMENT",
            "BUTTERFLY",
            "PASSENGER",
            "CLASSROOM",
        ] {
            assert!(
                !greylist().contains(innocent),
                "{innocent} is an ordinary word — a stem in greylist-stems.txt has gone too wide"
            );
        }
    }

    /// The base words rustrict misses, which are the reason the stem file
    /// exists at all.
    ///
    /// rustrict flags NEGROES, NEGROID and NEGROIDS but not NEGRO; POOFTER but
    /// not POOF; SMUTTY but not SMUT; and misses MONG entirely. A bot playing
    /// one of these in front of a child is the failure the greylist is for, so
    /// the gap being closed is worth asserting rather than assuming.
    #[test]
    fn the_base_words_rustrict_misses_are_greylisted() {
        for missed in [
            "NEGRO", "MONG", "POOF", "POON", "SMUT", "ABO", "WOG", "DAGO", "LEZ",
        ] {
            assert!(
                greylist().contains(missed),
                "{missed} is not greylisted — regenerate with the generate-greylist example"
            );
        }
    }

    /// Lookup takes the word as given, matches exactly, and short-circuits on
    /// an empty list.
    ///
    /// The empty case is the one that ships, and it is the one the engine pays
    /// for on every candidate — so "empty never matches, without hashing" is
    /// behaviour worth pinning rather than an implementation detail.
    #[test]
    fn lookup_is_exact_and_free_when_the_list_is_empty() {
        let list = parse("HONKY\nWOP");
        assert!(super::contains(&list, "HONKY"));
        assert!(!super::contains(&list, "HONKYTONK"), "whole word only");
        assert!(!super::contains(&list, "BASEMENT"));

        let empty = parse("# nothing but a comment");
        assert!(empty.is_empty());
        assert!(!super::contains(&empty, "HONKY"));
    }

    /// Engines avoid both lists, not only the grey one.
    #[test]
    fn engines_avoid_denied_words_too() {
        let grey = parse("DAMN");
        let denied = parse("HONKY");
        // Mirrors `is_avoided_by_engines` without depending on the committed
        // files being non-empty.
        let avoided = |word: &str| {
            let w = word.to_uppercase();
            grey.contains(&w) || denied.contains(&w)
        };
        assert!(avoided("damn"), "the grey list");
        assert!(avoided("HONKY"), "and the denied one, belt and braces");
        assert!(!avoided("BASEMENT"));
    }
}
