use std::collections::HashSet;
#[cfg(not(target_arch = "wasm32"))]
use std::sync::LazyLock;

use crate::model::{Alphabet, Letter, LetterMask, VariantRules, mask_insert};
#[cfg(not(target_arch = "wasm32"))]
use crate::tiered::TieredDictionary;

/// The denied words are already gone from these files — removed at import by
/// `wordlists::remove_denied`, as a step and a commit of its own, not filtered
/// here at startup. That keeps the dictionary the server validates against and
/// the text it serves to clients identical by construction rather than by both
/// remembering to call the same filter; filtering only one of the two would
/// leave the web client, which builds its own dictionary from that text, still
/// holding the words the denylist exists to remove. It also makes each removal
/// a diff somebody can read, which is the point of tracking these lists in
/// their own right.
///
/// Embedded at compile time for every non-wasm target (the server, and the
/// desktop client) — for those, this is free: no network cost, and disk
/// space isn't a constraint the way page-load size is. The wasm/web client
/// deliberately does *not* embed this (see `WordListDictionary::from_word_list`
/// and `sowpods_word_list()` below) — baking a ~2.7MB word list into every
/// page load doesn't scale once a second dictionary exists, and the server
/// already has this exact text in memory to serve on request instead.
#[cfg(not(target_arch = "wasm32"))]
const SOWPODS_WORD_FILE: &str = include_str!("sowpods.txt");

/// Same reasoning as `SOWPODS_WORD_FILE`, for the North American (ENABLE2K)
/// edition's dictionary.
#[cfg(not(target_arch = "wasm32"))]
const ENABLE2K_WORD_FILE: &str = include_str!("enable2k.txt");

/// Same reasoning as `SOWPODS_WORD_FILE`, for the German edition's
/// dictionary.
#[cfg(not(target_arch = "wasm32"))]
const GERMAN_WORD_FILE: &str = include_str!("german.txt");

/// Same reasoning as `SOWPODS_WORD_FILE`, for the Spanish edition's
/// dictionary. Plain, unannotated text — nothing here marks which "ch"/
/// "ll"/"rr" substrings are meant as a digraph tile, since the Spanish
/// edition deliberately doesn't require one (see `VariantRules::spanish`'s
/// doc comment).
#[cfg(not(target_arch = "wasm32"))]
const SPANISH_WORD_FILE: &str = include_str!("spanish.txt");

/// The raw SOWPODS word list text, for whoever serves it to clients that
/// fetch it at runtime instead of embedding it (see `crates/server-game`'s
/// `/dictionaries/:name` endpoint). Not meaningful on wasm, where nothing
/// has this text compiled in to begin with.
#[cfg(not(target_arch = "wasm32"))]
pub fn sowpods_word_list() -> &'static str {
    SOWPODS_WORD_FILE
}

/// Same as `sowpods_word_list`, for ENABLE2K.
#[cfg(not(target_arch = "wasm32"))]
pub fn enable2k_word_list() -> &'static str {
    ENABLE2K_WORD_FILE
}

/// Same as `sowpods_word_list`, for German.
#[cfg(not(target_arch = "wasm32"))]
pub fn german_word_list() -> &'static str {
    GERMAN_WORD_FILE
}

/// Same as `sowpods_word_list`, for Spanish.
#[cfg(not(target_arch = "wasm32"))]
pub fn spanish_word_list() -> &'static str {
    SPANISH_WORD_FILE
}

pub trait Dictionary {
    fn is_word(&self, word: &str) -> bool;

    /// A cursor type for incrementally searching this dictionary one
    /// letter at a time, used by move generation to prune a branch the
    /// moment the partial word it's building can't lead anywhere (see
    /// `expand_lane` in `generate.rs`) — without this, generation has to
    /// explore every rack-letter combination down to the full rack size
    /// before finding out most of them were dead ends, which is
    /// exponential in practice.
    ///
    /// The default `Cursor = ()` never prunes (`advance` always
    /// succeeds) — still correct for any `Dictionary` impl, just without
    /// the speedup. `WordListDictionary` overrides this with
    /// `SortedPrefixCursor`, a real implementation.
    type Cursor<'a>: PrefixCursor
    where
        Self: 'a;

    fn root_cursor(&self) -> Self::Cursor<'_>;

    /// Which letters could legally occupy one square, given the letters
    /// already fixed before and after it along the crossing direction —
    /// the cross-check `cache.rs` stores per cell. `before` is in reading
    /// order, so the candidate word is `before` + letter + `after`.
    ///
    /// A *batch* question rather than N independent ones, and that is the
    /// point: every candidate shares the same prefix and the same suffix.
    /// A prefix structure can walk `before` once and then spend one step
    /// per letter, where asking `is_word` a letter at a time forces it to
    /// re-derive the shared part every time.
    ///
    /// This default cannot exploit that — it builds each candidate word and
    /// asks `is_word`, which is what the engine did throughout — so it is
    /// correct for every implementation, including one whose cursor is the
    /// never-pruning `()`. Implementations with a real cursor should
    /// override it; see `TieredDictionary`.
    fn allowed_letters(
        &self,
        before: &[Letter],
        after: &[Letter],
        alphabet: &Alphabet,
    ) -> LetterMask {
        let mut mask = 0;
        let mut word = String::with_capacity(before.len() + 1 + after.len());
        for index in 0..alphabet.len() {
            let letter = Letter(index as u8);
            word.clear();
            for existing in before.iter().chain(&[letter]).chain(after.iter()) {
                match alphabet.to_grapheme(*existing) {
                    Some(grapheme) => word.extend(grapheme.chars()),
                    None => return mask,
                }
            }
            if self.is_word(&word) {
                mask_insert(&mut mask, letter);
            }
        }
        mask
    }
}

/// An incremental, letter-at-a-time search position into some backing
/// word structure. Different `Dictionary` implementations can back this
/// with completely different structures (a sorted array, a trie, ...) —
/// this is deliberately the *only* thing move generation needs from
/// whichever one is in use.
pub trait PrefixCursor: Copy {
    /// Narrows to the search state after also matching `letter`, or
    /// `None` if no word can possibly continue with it — the prune
    /// signal. `alphabet` resolves `letter` to the actual character it
    /// means under the current ruleset (see `VariantRules::alphabet`) —
    /// a cursor has no ambient alphabet of its own to assume.
    fn advance(&self, letter: Letter, alphabet: &Alphabet) -> Option<Self>;
}

impl PrefixCursor for () {
    fn advance(&self, _letter: Letter, _alphabet: &Alphabet) -> Option<Self> {
        Some(())
    }
}

pub struct WordListDictionary {
    words: HashSet<&'static str>,
    /// Tokenized into characters (not left as raw UTF-8 bytes) and sorted
    /// once at construction — the backing store for `SortedPrefixCursor`,
    /// which narrows a sub-slice one *character* at a time instead of
    /// re-searching the whole dictionary at every step of move generation.
    /// SOWPODS/ENABLE2K are both plain ASCII, so this only matters once a
    /// dictionary actually contains multi-byte UTF-8 words — but the
    /// search structure has to be character-indexed regardless of which
    /// dictionary it's built for, since byte-indexing silently desyncs
    /// the moment any word has a multi-byte character earlier in it.
    sorted_words: Vec<Vec<char>>,
}

/// The reference implementation, kept after `TieredDictionary` took over
/// production: it is the oracle the differential test in `tiered.rs` checks
/// against, and it is far simpler to reason about when a disagreement needs
/// explaining. Its per-edition constructors are gone — nothing but tests
/// builds one now, and they build from text.
impl WordListDictionary {
    #[cfg(not(target_arch = "wasm32"))]
    pub fn new() -> Self {
        Self::from_static_word_list(sowpods_word_list())
    }

    /// Builds a dictionary from word-list text fetched at runtime (one
    /// word per whitespace-separated token, same format as `sowpods.txt`)
    /// rather than embedded at compile time — this is how the wasm/web
    /// client gets its dictionary (see `crates/ui/src/app.rs`'s
    /// `load_client_dictionary`), fetching it from the server's
    /// `/dictionaries/:name` endpoint instead of bundling it into the page.
    ///
    /// `text` is leaked into a `&'static str` — accepted here since this is
    /// only ever called once per dictionary actually in use, for the
    /// program's whole lifetime (a page load, a server process), the same
    /// trade-off `include_str!` makes implicitly for the non-wasm path.
    pub fn from_word_list(text: String) -> Self {
        Self::from_static_word_list(Box::leak(text.into_boxed_str()))
    }

    fn from_static_word_list(text: &'static str) -> Self {
        let words: HashSet<&'static str> = text.split_whitespace().collect();
        let mut sorted_words: Vec<Vec<char>> =
            words.iter().map(|word| word.chars().collect()).collect();
        sorted_words.sort_unstable();
        Self {
            words,
            sorted_words,
        }
    }

    /// The starting point for an incremental prefix search — advance it
    /// one letter at a time as a candidate word is built up.
    pub fn prefix_cursor(&self) -> SortedPrefixCursor<'_> {
        SortedPrefixCursor {
            words: &self.sorted_words,
            depth: 0,
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Default for WordListDictionary {
    fn default() -> Self {
        Self::new()
    }
}

impl Dictionary for WordListDictionary {
    fn is_word(&self, word: &str) -> bool {
        self.words.contains(word)
    }

    type Cursor<'a> = SortedPrefixCursor<'a>;

    fn root_cursor(&self) -> Self::Cursor<'_> {
        self.prefix_cursor()
    }
}

/// A position in an incremental search over the sorted word list: `words`
/// is the sub-slice of (still sorted) entries that share the prefix
/// matched so far, and `depth` is how many *characters* that prefix has
/// (not bytes — a word's `Vec<char>` length, so a multi-byte character
/// still only ever counts as one step, unlike indexing raw UTF-8 bytes).
///
/// Advancing by one more letter binary-searches *within* `words` for the
/// narrower sub-range that also matches at position `depth` — a shrinking
/// window, not a fresh search over the whole dictionary — and each
/// comparison only looks at the one new character rather than
/// re-comparing the whole accumulated prefix. That's what makes this
/// cheap to call once per letter during move generation, unlike a
/// one-shot `is_prefix(&str)` which redoes all the earlier work every
/// time.
#[derive(Debug, Clone, Copy)]
pub struct SortedPrefixCursor<'a> {
    words: &'a [Vec<char>],
    depth: usize,
}

impl<'a> SortedPrefixCursor<'a> {
    fn char_at(word: &[char], index: usize) -> Option<char> {
        word.get(index).copied()
    }

    /// True if the prefix matched so far is itself a complete word. Since
    /// a strict prefix always sorts immediately before its extensions
    /// (`"A" < "AA" < "AAH"`), that's exactly the first entry of `words`,
    /// if it's the right length.
    pub fn is_word(&self) -> bool {
        self.words
            .first()
            .is_some_and(|word| word.len() == self.depth)
    }
}

impl<'a> PrefixCursor for SortedPrefixCursor<'a> {
    /// Narrows to words that also match `letter` at the next position(s),
    /// or `None` if nothing does — the prune signal: no word can possibly
    /// start with this prefix, so the caller doesn't need to keep
    /// building on top of it. A digraph `Letter` (e.g. Spanish's CH tile)
    /// resolves to two characters, so this narrows once per character in
    /// the grapheme — one placed tile can still consume more than one
    /// `depth` step, which is exactly what makes two different tilings of
    /// the same word (one tile spelling "ch", or two ordinary tiles
    /// spelling "c" then "h") both independently reach the same
    /// dictionary entry at the end.
    fn advance(&self, letter: Letter, alphabet: &Alphabet) -> Option<SortedPrefixCursor<'a>> {
        let grapheme = alphabet.to_grapheme(letter)?;
        let mut cursor = *self;
        for ch in grapheme.chars() {
            let target = Some(ch);
            let lo = cursor
                .words
                .partition_point(|word| Self::char_at(word, cursor.depth) < target);
            let hi = lo
                + cursor.words[lo..]
                    .partition_point(|word| Self::char_at(word, cursor.depth) == target);
            if lo == hi {
                return None;
            }
            cursor = SortedPrefixCursor {
                words: &cursor.words[lo..hi],
                depth: cursor.depth + 1,
            };
        }
        Some(cursor)
    }
}

// The dictionaries production actually uses. `TieredDictionary` replaced
// `WordListDictionary` here on 2026-07-30: same answers (a differential
// test in `tiered.rs` checks every word at every depth on all four lists),
// ~5x faster per cursor advance and ~6x smaller. `WordListDictionary`
// stays in the tree as that test's oracle and as the simpler reference
// implementation.
//
// Each needs its edition's alphabet, because the arena is ordered by
// letter index rather than by code point — Spanish files Ñ between N and O.

#[cfg(not(target_arch = "wasm32"))]
fn build(text: &'static str, rules: VariantRules) -> TieredDictionary {
    TieredDictionary::from_word_list(text, &rules.alphabet)
}

#[cfg(not(target_arch = "wasm32"))]
pub static SOWPODS: LazyLock<TieredDictionary> =
    LazyLock::new(|| build(sowpods_word_list(), VariantRules::official()));

#[cfg(not(target_arch = "wasm32"))]
pub static ENABLE2K: LazyLock<TieredDictionary> =
    LazyLock::new(|| build(enable2k_word_list(), VariantRules::north_american()));

#[cfg(not(target_arch = "wasm32"))]
pub static GERMAN: LazyLock<TieredDictionary> =
    LazyLock::new(|| build(german_word_list(), VariantRules::german()));

#[cfg(not(target_arch = "wasm32"))]
pub static SPANISH: LazyLock<TieredDictionary> =
    LazyLock::new(|| build(spanish_word_list(), VariantRules::spanish()));

#[cfg(not(target_arch = "wasm32"))]
pub fn is_word(word: &str) -> bool {
    SOWPODS.is_word(word)
}

/// The alphabet a `VariantRules.language` value implies, without needing
/// the word list.
///
/// The wasm client fetches its dictionary text at runtime and so has to
/// build the structure itself — and the structure is ordered by letter
/// index, not code point, so it cannot be built without knowing the
/// edition's alphabet. Available on wasm too, unlike the dictionaries
/// themselves.
pub fn alphabet_by_name(language: &str) -> Option<Alphabet> {
    let rules = match language {
        "sowpods" => VariantRules::official(),
        "enable2k" => VariantRules::north_american(),
        "german" => VariantRules::german(),
        "spanish" => VariantRules::spanish(),
        _ => return None,
    };
    Some(rules.alphabet)
}

/// Resolves a `VariantRules.language` value to its backing dictionary — the
/// one choke point every server/desktop/engine call site uses instead of
/// hardcoding `&*SOWPODS`, so a game's actual edition (not just whichever
/// dictionary happened to be wired in first) decides what it's validated
/// against.
#[cfg(not(target_arch = "wasm32"))]
pub fn dictionary_by_name(name: &str) -> Option<&'static TieredDictionary> {
    match name {
        "sowpods" => Some(&*SOWPODS),
        "enable2k" => Some(&*ENABLE2K),
        "german" => Some(&*GERMAN),
        "spanish" => Some(&*SPANISH),
        _ => None,
    }
}

/// Builds every dictionary, so the first request that needs one doesn't.
///
/// `dictionary_by_name` derefs a `LazyLock`, and `GameSession::new` calls it
/// while creating a game — so without this, the first game of an edition
/// after a server start builds the whole structure inside that request. On
/// the production VM that is 310ms for sowpods and 937ms for german, which
/// the player sees as the New Game button hanging. It is also invisible to
/// the bot-move timing, which spans only `engine.choose_action` in a later
/// request.
///
/// Deliberately only *builds* — no attempt to warm CPU caches by walking.
/// That warmth wouldn't survive a quiet period between games anyway, and
/// normal play restores it for free; construction is the part that is
/// permanent once paid.
///
/// Call it off the request path — it is hundreds of milliseconds of pure
/// CPU, so on an async runtime it belongs in `spawn_blocking`.
#[cfg(not(target_arch = "wasm32"))]
pub fn build_all_dictionaries() {
    for name in ["sowpods", "enable2k", "german", "spanish"] {
        if let Some(dictionary) = dictionary_by_name(name) {
            std::hint::black_box(dictionary.word_count());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Dictionary, ENABLE2K, GERMAN, PrefixCursor, SOWPODS, SPANISH, SortedPrefixCursor,
        dictionary_by_name, enable2k_word_list, german_word_list, is_word, sowpods_word_list,
        spanish_word_list,
    };
    use crate::model::{Alphabet, Letter, VariantRules};

    /// The four editions, their word lists and the alphabets those lists must
    /// be writable in.
    fn every_word_list() -> [(&'static str, &'static str, VariantRules); 4] {
        [
            ("sowpods", sowpods_word_list(), VariantRules::official()),
            (
                "enable2k",
                enable2k_word_list(),
                VariantRules::north_american(),
            ),
            ("german", german_word_list(), VariantRules::german()),
            ("spanish", spanish_word_list(), VariantRules::spanish()),
        ]
    }

    /// Every committed word list is exactly what `normalise` would produce from
    /// it — uppercase, inside its alphabet, playable length, sorted and deduped
    /// in byte order.
    ///
    /// One assertion for the lot, because a fixed point proves every property
    /// at once and there is no second copy of the rules to drift out of step
    /// with the importer. It fails the moment somebody changes an alphabet, the
    /// length bounds, or re-imports a list without normalising it — which is
    /// exactly when a silent wrong answer would otherwise be easiest to ship.
    ///
    /// The property this replaces checked ordering and blank lines only, so it
    /// would not have noticed a lowercase word, a nineteen-letter word, or
    /// `KWIK` in the Spanish list.
    ///
    /// Byte order specifically (`LC_ALL=C sort -u`) is code-point order for
    /// UTF-8 and therefore the order the prefix cursor's binary search assumes.
    /// A locale-aware sort is *not* equivalent — German collation files `Ä`
    /// beside `A` — and would quietly break lookups on the two non-ASCII lists
    /// while leaving the two ASCII ones looking perfect.
    #[test]
    fn every_word_list_is_a_fixed_point_of_the_normaliser() {
        for (name, text, rules) in every_word_list() {
            assert!(!text.is_empty(), "{name} is empty");
            let normalised = crate::wordlists::normalise(text, &rules.alphabet);
            if normalised != text {
                let before: Vec<&str> = text.lines().collect();
                let after: Vec<&str> = normalised.lines().collect();
                let first = before
                    .iter()
                    .zip(&after)
                    .position(|(b, a)| b != a)
                    .unwrap_or(before.len().min(after.len()));
                // Reported by line, and separately by byte, because a list can
                // agree line-for-line and still differ — a missing trailing
                // newline is exactly one invisible byte, and "no difference
                // found" would be a maddening thing for this test to say.
                assert_eq!(
                    before,
                    after,
                    "{name} differs from its normalised form: {} lines committed, {} after \
                     normalising, first difference at line {}. Re-import it — see \
                     docs/3.5-word-lists-and-dictionaries.md.",
                    before.len(),
                    after.len(),
                    first + 1,
                );
                panic!(
                    "{name} has the right {} lines but differs by {} bytes — most likely the \
                     trailing newline. Re-import it.",
                    before.len(),
                    (text.len() as isize - normalised.len() as isize).abs(),
                );
            }
        }
    }

    /// No committed word list holds a denied word.
    ///
    /// Separate from the fixed-point test on purpose. That one is about the
    /// *form* of a list; this is about its *content*, and they fail for
    /// different reasons: the first when an import skipped normalising, the
    /// second when the denylist grew and the lists were not regenerated. A
    /// denied word left in a list is playable and enumerable by an engine,
    /// which is the whole thing the denylist exists to prevent, so it must not
    /// be possible to ship it by forgetting a step.
    #[test]
    fn no_committed_word_list_holds_a_denied_word() {
        for (name, text, _) in every_word_list() {
            if let Some(denied) = text.lines().find(|word| crate::wordlists::is_denied(word)) {
                panic!(
                    "{name} still contains the denied word {denied:?} — regenerate every \
                     edition when the denylist changes, see docs/3.5-word-lists-and-dictionaries.md"
                );
            }
        }
    }

    fn advance_all<C: PrefixCursor>(mut cursor: C, word: &str) -> Option<C> {
        let alphabet = Alphabet::latin26();
        for ch in word.chars() {
            cursor = cursor.advance(Letter::from(ch), &alphabet)?;
        }
        Some(cursor)
    }

    #[test]
    fn sowpods_lookup_works() {
        assert!(is_word("ACE"));
        assert!(!is_word("NOTAWORD"));
    }

    #[test]
    fn dictionary_by_name_resolves_every_known_dictionary() {
        assert!(std::ptr::eq(
            dictionary_by_name("sowpods").unwrap(),
            &*SOWPODS
        ));
        assert!(std::ptr::eq(
            dictionary_by_name("enable2k").unwrap(),
            &*ENABLE2K
        ));
        assert!(std::ptr::eq(
            dictionary_by_name("german").unwrap(),
            &*GERMAN
        ));
        assert!(std::ptr::eq(
            dictionary_by_name("spanish").unwrap(),
            &*SPANISH
        ));
        assert!(dictionary_by_name("not-a-real-dictionary").is_none());
    }

    #[test]
    fn german_dictionary_recognizes_a_real_umlaut_word() {
        assert!(GERMAN.is_word("ÖL"));
        assert!(!GERMAN.is_word("NOTAWORD"));
    }

    #[test]
    fn german_prefix_cursor_finds_a_word_with_an_umlaut_letter() {
        let rules = VariantRules::german();
        let cursor = advance_all_with(GERMAN.root_cursor(), "ÖL", &rules.alphabet)
            .expect("ÖL should be reachable through the real German dictionary");
        assert!(cursor.is_word());
    }

    #[test]
    fn spanish_dictionary_recognizes_a_real_digraph_word() {
        assert!(SPANISH.is_word("CARRO"));
        assert!(SPANISH.is_word("CALLE"));
        assert!(SPANISH.is_word("CHICO"));
        assert!(!SPANISH.is_word("NOTAWORD"));
    }

    /// The core design decision this phase is built on: both tilings of
    /// the same word validate, since the dictionary is plain unannotated
    /// text and `advance` just narrows once per character in whichever
    /// grapheme was actually placed.
    #[test]
    fn spanish_prefix_cursor_accepts_both_tilings_of_the_same_word() {
        let rules = VariantRules::spanish();
        let rr = rules.alphabet.to_letter("RR").expect("RR is a real tile");
        let r = rules.alphabet.to_letter("R").expect("R is a real tile");

        let via_digraph_tile = advance_letters(
            SPANISH.root_cursor(),
            &[c(&rules, 'C'), c(&rules, 'A'), rr, c(&rules, 'O')],
        )
        .expect("CARRO should be reachable via the RR tile");
        assert!(via_digraph_tile.is_word());

        let via_two_ordinary_tiles = advance_letters(
            SPANISH.root_cursor(),
            &[c(&rules, 'C'), c(&rules, 'A'), r, r, c(&rules, 'O')],
        )
        .expect("CARRO should also be reachable via two separate R tiles");
        assert!(via_two_ordinary_tiles.is_word());
    }

    fn c(rules: &VariantRules, ch: char) -> Letter {
        rules
            .alphabet
            .to_letter(&ch.to_string())
            .expect("single ASCII letter should be a real tile")
    }

    /// Generic over the cursor so the same assertions cover both
    /// implementations — the statics are the tiered one now, while the
    /// locally-built `WordListDictionary` cases still exercise the
    /// reference one.
    fn advance_letters<C: PrefixCursor>(mut cursor: C, letters: &[Letter]) -> Option<C> {
        let alphabet = &VariantRules::spanish().alphabet;
        for &letter in letters {
            cursor = cursor.advance(letter, alphabet)?;
        }
        Some(cursor)
    }

    #[test]
    fn prefix_cursor_finds_real_words_letter_by_letter() {
        let cursor =
            advance_all(SOWPODS.root_cursor(), "LEXICON").expect("LEXICON should be reachable");
        assert!(cursor.is_word());
    }

    #[test]
    fn prefix_cursor_recognizes_a_prefix_that_is_not_yet_a_word() {
        // "LEXIC" isn't a word on its own, but it is a valid prefix
        // (LEXICA, LEXICON, ...) — the cursor should still exist, just
        // not report is_word.
        let cursor =
            advance_all(SOWPODS.root_cursor(), "LEXIC").expect("LEXIC should be a live prefix");
        assert!(!cursor.is_word());
    }

    #[test]
    fn prefix_cursor_prunes_a_dead_end() {
        assert!(advance_all(SOWPODS.root_cursor(), "ZZZZZ").is_none());
    }

    #[test]
    fn prefix_cursor_finds_short_words() {
        let cursor = advance_all(SOWPODS.root_cursor(), "ZA").expect("ZA should be reachable");
        assert!(cursor.is_word());
    }

    /// A synthetic, non-ASCII, >26-letter toy alphabet — not a real shipped
    /// language, just enough to prove the cursor is genuinely
    /// character-indexed rather than byte-indexed. `É` is two UTF-8 bytes;
    /// the old byte-indexed cursor would desync `depth` from "letters
    /// matched" the moment it appeared anywhere but the very end of a word,
    /// silently corrupting every comparison after it.
    fn toy_alphabet() -> Alphabet {
        Alphabet::from_chars(('A'..='Z').chain(['É', 'Ñ']))
    }

    fn toy_words(words: &[&str]) -> Vec<Vec<char>> {
        let mut sorted: Vec<Vec<char>> = words.iter().map(|w| w.chars().collect()).collect();
        sorted.sort_unstable();
        sorted
    }

    #[test]
    fn prefix_cursor_finds_a_word_with_a_multi_byte_letter_in_the_middle() {
        let sorted = toy_words(&["ÉCLAT", "ÉCLATS", "CAT"]);
        let alphabet = toy_alphabet();
        let root = SortedPrefixCursor {
            words: &sorted,
            depth: 0,
        };
        let cursor = advance_all_with(root, "ÉCLAT", &alphabet)
            .expect("ÉCLAT should be reachable despite É being multi-byte");
        assert!(cursor.is_word());
    }

    #[test]
    fn prefix_cursor_still_recognizes_a_live_prefix_past_a_multi_byte_letter() {
        let sorted = toy_words(&["ÉCLAT", "ÉCLATS", "CAT"]);
        let alphabet = toy_alphabet();
        let root = SortedPrefixCursor {
            words: &sorted,
            depth: 0,
        };
        // "ÉCLAT" is itself a complete word, but also a live prefix of
        // "ÉCLATS" — both should be true, same as the plain-ASCII
        // `prefix_cursor_recognizes_a_prefix_that_is_not_yet_a_word` case.
        let cursor = advance_all_with(root, "ÉCLAT", &alphabet).expect("should be reachable");
        assert!(cursor.is_word());
        let extended =
            advance_all_with(root, "ÉCLATS", &alphabet).expect("ÉCLATS should be reachable too");
        assert!(extended.is_word());
    }

    #[test]
    fn prefix_cursor_prunes_a_dead_end_with_a_multi_byte_letter() {
        let sorted = toy_words(&["ÉCLAT", "CAT"]);
        let alphabet = toy_alphabet();
        let root = SortedPrefixCursor {
            words: &sorted,
            depth: 0,
        };
        assert!(advance_all_with(root, "ÑOPE", &alphabet).is_none());
    }

    fn advance_all_with<C: PrefixCursor>(
        mut cursor: C,
        word: &str,
        alphabet: &Alphabet,
    ) -> Option<C> {
        for ch in word.chars() {
            let letter = alphabet.to_letter(&ch.to_string())?;
            cursor = cursor.advance(letter, alphabet)?;
        }
        Some(cursor)
    }
}
