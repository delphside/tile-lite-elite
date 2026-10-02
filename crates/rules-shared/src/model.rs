use serde::{Deserialize, Serialize};
use std::fmt::{Display, Formatter};
use std::ops::Neg;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Direction {
    Horizontal,
    Vertical,
}

impl Neg for Direction {
    type Output = Direction;

    fn neg(self) -> Self::Output {
        match self {
            Direction::Horizontal => Direction::Vertical,
            Direction::Vertical => Direction::Horizontal,
        }
    }
}

impl Display for Direction {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Direction::Horizontal => write!(f, "Horizontal"),
            Direction::Vertical => write!(f, "Vertical"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Position {
    pub x: u8,
    pub y: u8,
}

impl Position {
    pub const fn new(x: u8, y: u8) -> Self {
        Self { x, y }
    }

    pub fn try_step_forward(&self, direction: Direction, width: u8, height: u8) -> Option<Self> {
        match direction {
            Direction::Horizontal if self.x + 1 < width => Some(Self::new(self.x + 1, self.y)),
            Direction::Vertical if self.y + 1 < height => Some(Self::new(self.x, self.y + 1)),
            _ => None,
        }
    }

    pub fn try_step_backward(&self, direction: Direction) -> Option<Self> {
        match direction {
            Direction::Horizontal if self.x > 0 => Some(Self::new(self.x - 1, self.y)),
            Direction::Vertical if self.y > 0 => Some(Self::new(self.x, self.y - 1)),
            _ => None,
        }
    }

    pub const fn to_index(self, width: usize) -> usize {
        (self.y as usize) * width + (self.x as usize)
    }
}

impl Display for Position {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}{}", (self.x + b'A') as char, self.y + 1)
    }
}

impl FromStr for Position {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if s.len() < 2 {
            return Err(format!("Invalid position: {s}"));
        }

        let mut chars = s.chars();
        let column = chars
            .next()
            .ok_or_else(|| format!("Invalid position: {s}"))?;

        if !(('A'..='O').contains(&column)) {
            return Err(format!("Invalid position: {s}"));
        }

        let row_str: String = chars.collect();
        let row = row_str
            .parse::<u8>()
            .map_err(|_| format!("Invalid position: {s}"))?;

        if !(1..=15).contains(&row) {
            return Err(format!("Invalid position: {s}"));
        }

        Ok(Self::new(column as u8 - b'A', row - 1))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Letter(pub u8);

impl Letter {
    pub const FIRST_ASCII: u8 = b'A';

    pub const fn as_byte(self) -> u8 {
        self.0
    }

    pub const fn as_char(self) -> char {
        (self.0 + Self::FIRST_ASCII) as char
    }

    pub const fn as_usize(self) -> usize {
        self.0 as usize
    }
}

impl From<u8> for Letter {
    fn from(value: u8) -> Self {
        Self(value)
    }
}

impl From<char> for Letter {
    fn from(value: char) -> Self {
        Self(value as u8 - Self::FIRST_ASCII)
    }
}

impl Display for Letter {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_char())
    }
}

/// A tile's face — most are a single Unicode codepoint, but traditional
/// Castilian Spanish's CH/LL/RR digraph tiles are genuinely two: one
/// physical tile, one board square, one rack slot, that happens to
/// display two characters. `Copy` and fixed-size (never heap-allocated),
/// so an `Alphabet`'s `Vec<Grapheme>` is one contiguous block — unlike a
/// `Vec<Box<str>>`, which would scatter one small heap allocation per
/// entry. Deliberately capped at two characters: that's the actual scope
/// (a handful of real digraph tiles), not a general grapheme-cluster
/// facility for arbitrary complex scripts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Grapheme {
    Single(char),
    Double(char, char),
}

impl Grapheme {
    pub fn chars(self) -> GraphemeChars {
        GraphemeChars {
            grapheme: self,
            index: 0,
        }
    }
}

impl Display for Grapheme {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        for ch in self.chars() {
            write!(f, "{ch}")?;
        }
        Ok(())
    }
}

/// Yields a `Grapheme`'s one or two characters in order — no allocation,
/// since `Grapheme` is already `Copy`.
pub struct GraphemeChars {
    grapheme: Grapheme,
    index: u8,
}

impl Iterator for GraphemeChars {
    type Item = char;

    fn next(&mut self) -> Option<char> {
        let result = match (self.grapheme, self.index) {
            (Grapheme::Single(a), 0) => Some(a),
            (Grapheme::Double(a, _), 0) => Some(a),
            (Grapheme::Double(_, b), 1) => Some(b),
            _ => None,
        };
        if result.is_some() {
            self.index += 1;
        }
        result
    }
}

/// The ordered set of graphemes a ruleset's `Letter`s actually mean —
/// `Letter` is just a compact index (0.., see `Letter::as_usize`), and
/// without an `Alphabet` to look it up in, that index has no inherent
/// meaning. Most editions use single-character graphemes
/// (`Alphabet::latin26()`, or `latin26()` plus a few accented letters),
/// but a `Letter` can also mean a digraph tile — see `Grapheme`. Nothing
/// in `rules-shared`'s core logic (dictionary search, cross-checks,
/// scoring) hardcodes a single-character assumption anymore — it always
/// goes through whichever alphabet the current `VariantRules` carries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Alphabet {
    graphemes: Vec<Grapheme>,
}

impl Alphabet {
    /// The standard 26-letter Latin alphabet (A-Z) — every edition this
    /// project ships today uses this.
    pub fn latin26() -> Self {
        Self::from_chars('A'..='Z')
    }

    /// Builds an alphabet from an explicit, ordered list of single
    /// characters — for a language whose letters aren't a dense run
    /// starting at 'A' (accented Latin, a different script, ...).
    /// `Letter(i)` means `chars[i]`, for whatever order is given here.
    pub fn from_chars(chars: impl IntoIterator<Item = char>) -> Self {
        Self {
            graphemes: chars.into_iter().map(Grapheme::Single).collect(),
        }
    }

    /// Builds an alphabet from an explicit, ordered list of graphemes,
    /// some of which may be digraphs — for a digraph-tile edition
    /// (Spanish's CH/LL/RR). `Letter(i)` means `graphemes[i]`.
    pub fn from_graphemes(graphemes: impl IntoIterator<Item = Grapheme>) -> Self {
        Self {
            graphemes: graphemes.into_iter().collect(),
        }
    }

    pub fn to_grapheme(&self, letter: Letter) -> Option<Grapheme> {
        self.graphemes.get(letter.as_usize()).copied()
    }

    /// Resolves the `Letter` whose grapheme's rendered text exactly equals
    /// `s` — this is an exact match, not a longest-match tokenizer over
    /// free text: every caller already hands this an already-delimited,
    /// single-tile string (a wire DTO field, a rack tile's known content),
    /// never a longer run of concatenated text that would need splitting
    /// up.
    pub fn to_letter(&self, s: &str) -> Option<Letter> {
        self.graphemes
            .iter()
            .position(|candidate| candidate.chars().eq(s.chars()))
            .map(|index| Letter(index as u8))
    }

    pub fn len(&self) -> usize {
        self.graphemes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.graphemes.is_empty()
    }

    /// Every character appearing in any of this alphabet's graphemes.
    ///
    /// Deliberately not the graphemes themselves. Spanish's CH/LL/RR are
    /// genuine digraph tiles, but a word list is plain unannotated text, so
    /// `C`, `H`, `L` and `R` are all ordinary members of it — a word is
    /// writable in an edition if every one of its characters appears here,
    /// regardless of how it would be tiled.
    ///
    /// Used by `wordlists::normalise` to decide which imported words this
    /// edition can hold at all.
    pub fn chars(&self) -> impl Iterator<Item = char> + '_ {
        self.graphemes.iter().flat_map(|grapheme| grapheme.chars())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Tile {
    Letter(Letter),
    Blank { acting_as: Option<Letter> },
}

impl Tile {
    pub fn letter(self) -> Option<Letter> {
        match self {
            Tile::Letter(letter) => Some(letter),
            Tile::Blank { acting_as } => acting_as,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Premium {
    Blank,
    DoubleLetter,
    TripleLetter,
    DoubleWord,
    TripleWord,
}

impl Premium {
    pub const fn letter_multiplier(self) -> u8 {
        match self {
            Premium::DoubleLetter => 2,
            Premium::TripleLetter => 3,
            _ => 1,
        }
    }

    pub const fn word_multiplier(self) -> u8 {
        match self {
            Premium::DoubleWord => 2,
            Premium::TripleWord => 3,
            _ => 1,
        }
    }
}

/// Widened from `u32`: still a plain bitmask (one bit per letter, cheap
/// branchless test/set), but `u32` capped every ruleset at 32 distinct
/// letters. `u64` comfortably covers any realistic single-codepoint
/// alphabet (Cyrillic ~33, for instance) without needing a dynamic bitset.
pub type LetterMask = u64;
pub type Score = i16;

/// Every `Rack`/`VariantRules` letter-indexed array is a fixed array sized
/// to this, rather than growing per-alphabet (`Vec`) — deliberately, to
/// keep `Rack` cheaply `Copy` (it's passed and stored by value throughout
/// move generation and game state) instead of a heap-allocated `Vec` no
/// alphabet in production actually needs yet. Matches `LetterMask`'s bit
/// width, since a letter index that didn't fit in the mask couldn't be
/// checked/pruned anyway.
pub const MAX_ALPHABET_SIZE: usize = 64;

/// The tie to `LetterMask`'s width above is load-bearing, not decorative.
/// `mask_insert` shifts by the letter index, and a shift past the type's
/// width is only a panic in debug — in release the shift amount is masked,
/// so letter 74 would silently become bit 10 and alias letter 10 in every
/// cross-check. Raising `MAX_ALPHABET_SIZE` therefore has to widen
/// `LetterMask` in the same commit, and this fails the build otherwise.
///
/// Raising it is otherwise safe: `deserialize_letter_array` rejects arrays
/// *longer* than the constant, so persisted 64-entry racks keep loading.
/// The real cost is that `RuleCache` holds two letter-indexed score arrays
/// per cell — 225 cells, ~61 KB today — so doubling the constant nearly
/// doubles the hottest structure move generation reads.
const _: () = assert!(
    MAX_ALPHABET_SIZE <= LetterMask::BITS as usize,
    "MAX_ALPHABET_SIZE must fit LetterMask, or mask_insert aliases letters in release"
);

pub const FULL_LETTER_MASK: LetterMask = LetterMask::MAX;

pub const fn mask_contains(mask: LetterMask, letter: Letter) -> bool {
    (mask & (1 << letter.as_usize())) != 0
}

pub fn mask_insert(mask: &mut LetterMask, letter: Letter) {
    *mask |= 1 << letter.as_usize();
}

pub fn mask_remove(mask: &mut LetterMask, letter: Letter) {
    *mask &= !(1 << letter.as_usize());
}

pub const fn mask_is_empty(mask: LetterMask) -> bool {
    mask == 0
}

pub const fn mask_is_full(mask: LetterMask) -> bool {
    mask == FULL_LETTER_MASK
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rack {
    // `std::array::from_fn`/serde's own array impls only go up to 32
    // elements natively — `Default` and `Serialize`/`Deserialize` are
    // written by hand below rather than pulling in a
    // fixed-size-array-serde crate for this one field.
    #[serde(
        serialize_with = "serialize_letter_array",
        deserialize_with = "deserialize_letter_array"
    )]
    pub counts: [u8; MAX_ALPHABET_SIZE],
    pub blanks: u8,
}

impl Default for Rack {
    fn default() -> Self {
        Self {
            counts: [0; MAX_ALPHABET_SIZE],
            blanks: 0,
        }
    }
}

fn serialize_letter_array<S: serde::Serializer>(
    counts: &[u8; MAX_ALPHABET_SIZE],
    serializer: S,
) -> Result<S::Ok, S::Error> {
    counts.as_slice().serialize(serializer)
}

fn deserialize_letter_array<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<[u8; MAX_ALPHABET_SIZE], D::Error> {
    let values = Vec::<u8>::deserialize(deserializer)?;
    if values.len() > MAX_ALPHABET_SIZE {
        return Err(serde::de::Error::invalid_length(
            values.len(),
            &"at most MAX_ALPHABET_SIZE letter counts",
        ));
    }
    // Accepts anything up to MAX_ALPHABET_SIZE, zero-padding the rest —
    // not just an exact match — so a rack persisted before this array was
    // widened (26 counts) still deserializes correctly instead of every
    // pre-existing saved game failing to load.
    let mut counts = [0u8; MAX_ALPHABET_SIZE];
    counts[..values.len()].copy_from_slice(&values);
    Ok(counts)
}

impl Rack {
    pub fn count(self) -> u8 {
        self.counts.iter().sum::<u8>() + self.blanks
    }

    pub fn is_empty(self) -> bool {
        self.count() == 0
    }

    pub fn contains_letter(self, letter: Letter) -> bool {
        self.counts[letter.as_usize()] > 0
    }

    pub fn add_letter(&mut self, letter: Letter) {
        self.counts[letter.as_usize()] += 1;
    }

    pub fn remove_letter(&mut self, letter: Letter) -> bool {
        let count = &mut self.counts[letter.as_usize()];
        if *count > 0 {
            *count -= 1;
            true
        } else {
            false
        }
    }

    pub fn remove_blank(&mut self) -> bool {
        if self.blanks > 0 {
            self.blanks -= 1;
            true
        } else {
            false
        }
    }

    pub fn consume_tile(&mut self, tile: Tile) -> bool {
        match tile {
            Tile::Letter(letter) => self.remove_letter(letter),
            Tile::Blank { acting_as: Some(_) } => self.remove_blank(),
            Tile::Blank { acting_as: None } => false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct VariantRules {
    /// The bundled edition name ("official", "north_american", ...) — board
    /// layout, letter values, tile distribution, and dictionary all travel
    /// together under this one name (real Scrabble editions don't mix and
    /// match these independently, so neither does this type).
    pub name: String,
    pub language: String,
    /// The characters this ruleset's `Letter`s mean — see `Alphabet`.
    /// Every edition today is `Alphabet::latin26()`, but nothing else in
    /// this type or in `rules-shared`'s search/scoring logic assumes that.
    pub alphabet: Alphabet,
    pub letter_values: [u8; MAX_ALPHABET_SIZE],
    pub tile_distribution: [u8; MAX_ALPHABET_SIZE],
    pub blank_tiles: u8,
    pub rack_size: u8,
    pub width: u8,
    pub height: u8,
    pub bingo_bonus: Score,
    pub premiums: [Premium; 225],
}

impl VariantRules {
    /// The actual grapheme `letter` represents under this ruleset's
    /// alphabet — unlike `Letter::as_char()` (a fixed ASCII-offset guess
    /// that's only ever right for the default Latin alphabet, and only
    /// ever one character), this is correct for whichever alphabet this
    /// specific ruleset actually uses, including multi-character digraph
    /// tiles (Spanish's CH/LL/RR).
    pub fn letter_grapheme(&self, letter: Letter) -> Grapheme {
        self.alphabet
            .to_grapheme(letter)
            .expect("Letter should be valid for this ruleset's alphabet")
    }

    /// Every letter this ruleset's alphabet defines, in index order —
    /// replaces the old global `ALPHABET` constant, which silently assumed
    /// every ruleset used the same 26-letter Latin alphabet.
    pub fn letters(&self) -> impl Iterator<Item = Letter> + '_ {
        (0..self.alphabet.len()).map(|index| Letter(index as u8))
    }

    pub fn official() -> Self {
        Self {
            name: "official".to_string(),
            language: "sowpods".to_string(),
            alphabet: Alphabet::latin26(),
            letter_values: pad::<26>([
                1, 3, 3, 2, 1, 4, 2, 4, 1, 8, 5, 1, 3, 1, 1, 3, 10, 1, 1, 1, 1, 4, 4, 8, 4, 10,
            ]),
            tile_distribution: pad::<26>([
                9, 2, 2, 4, 12, 2, 3, 2, 9, 1, 1, 4, 2, 6, 8, 2, 1, 6, 4, 6, 4, 2, 2, 1, 2, 1,
            ]),
            blank_tiles: 2,
            rack_size: 7,
            width: 15,
            height: 15,
            bingo_bonus: 50,
            premiums: house_premiums(),
        }
    }

    /// North American English Scrabble (TWL/NWL word list territory).
    /// Real North American (Hasbro) and International (Mattel) sets are
    /// economically identical — same 100 tiles, same letter values, same
    /// tiles — the only real-world difference is the word list, so this
    /// deliberately duplicates `official()`'s numbers verbatim rather than
    /// deriving from it: it's a coincidence that they start out equal, not
    /// a guarantee, and the two should be free to diverge independently if
    /// either edition's numbers are ever tuned. The board is not part of
    /// that: every edition shares `house_premiums()`.
    pub fn north_american() -> Self {
        Self {
            name: "north_american".to_string(),
            language: "enable2k".to_string(),
            alphabet: Alphabet::latin26(),
            letter_values: pad::<26>([
                1, 3, 3, 2, 1, 4, 2, 4, 1, 8, 5, 1, 3, 1, 1, 3, 10, 1, 1, 1, 1, 4, 4, 8, 4, 10,
            ]),
            tile_distribution: pad::<26>([
                9, 2, 2, 4, 12, 2, 3, 2, 9, 1, 1, 4, 2, 6, 8, 2, 1, 6, 4, 6, 4, 2, 2, 1, 2, 1,
            ]),
            blank_tiles: 2,
            rack_size: 7,
            width: 15,
            height: 15,
            bingo_bonus: 50,
            premiums: house_premiums(),
        }
    }

    /// German Scrabble — a genuinely distinct alphabet (A-Z plus Ä/Ö/Ü, 29
    /// letters total) with its own point values/distribution, verified
    /// against two independent sources (Wikipedia's Scrabble letter
    /// distributions page and gtoal.com/scrabble/details/german): 100
    /// letter tiles + 2 blanks = 102 total (vs. English's 100). No ß tile —
    /// real German Scrabble sets have none; ß-words are physically played
    /// as two separate S tiles (`STRASSE`, not `STRAßE`), which is exactly
    /// why the German S count (7) is higher than English's (4). The bingo
    /// bonus matches `official()` — standard across language editions —
    /// and the board is `house_premiums()`, as every edition's is.
    pub fn german() -> Self {
        Self {
            name: "german".to_string(),
            language: "german".to_string(),
            alphabet: Alphabet::from_chars(('A'..='Z').chain(['Ä', 'Ö', 'Ü'])),
            // A..Z, then Ä, Ö, Ü.
            letter_values: pad::<29>([
                1, 3, 4, 1, 1, 4, 2, 2, 1, 6, 4, 2, 3, 1, 2, 4, 10, 1, 1, 1, 1, 6, 3, 8, 10, 3, 6,
                8, 6,
            ]),
            tile_distribution: pad::<29>([
                5, 2, 2, 4, 15, 2, 3, 4, 6, 1, 2, 3, 4, 9, 3, 1, 1, 6, 7, 6, 6, 1, 1, 1, 1, 1, 1,
                1, 1,
            ]),
            blank_tiles: 2,
            rack_size: 7,
            width: 15,
            height: 15,
            bingo_bonus: 50,
            premiums: house_premiums(),
        }
    }

    /// Traditional Castilian Spanish Scrabble — predates, and was never
    /// updated for, the Real Academia Española's 2010 decision to drop
    /// CH/LL as separate alphabet letters; the physical tile set still
    /// uses CH, LL, and RR as genuine digraph tiles (one board square,
    /// one rack slot, one point value each), verified against two
    /// independent sources (gtoal.com/scrabble/details/spanish,
    /// Wikipedia's Scrabble letter distributions page). K and W are
    /// absent entirely (rarely used in Spanish, zero tiles in the real
    /// set) rather than present with a zero count. 25 single letters + 3
    /// digraphs + 2 blanks = 100 tiles.
    ///
    /// Real FISE tournament rules forbid substituting two ordinary tiles
    /// for a digraph tile — you must hold the actual CH tile to play a
    /// word needing "ch". This deliberately does **not** enforce that:
    /// both the digraph tile (one square) and two ordinary tiles (two
    /// squares) are accepted ways to spell the same word. That's not a
    /// data limitation, it's what lets the dictionary stay completely
    /// unannotated plain text — `SortedPrefixCursor::advance` just
    /// narrows once per character in whichever grapheme was placed, so
    /// both tilings independently reach the same entry.
    pub fn spanish() -> Self {
        Self {
            name: "spanish".to_string(),
            language: "spanish".to_string(),
            // A-Z minus K,W, plus Ñ, then the three digraph tiles.
            alphabet: Alphabet::from_graphemes(
                "ABCDEFGHIJLMNÑOPQRSTUVXYZ"
                    .chars()
                    .map(Grapheme::Single)
                    .chain([
                        Grapheme::Double('C', 'H'),
                        Grapheme::Double('L', 'L'),
                        Grapheme::Double('R', 'R'),
                    ]),
            ),
            letter_values: pad::<28>([
                1, 3, 3, 2, 1, 4, 2, 4, 1, 8, 1, 3, 1, 8, 1, 3, 5, 1, 1, 1, 1, 4, 8, 4, 10, 5, 8, 8,
            ]),
            tile_distribution: pad::<28>([
                12, 2, 4, 5, 12, 1, 2, 2, 6, 1, 4, 2, 5, 1, 9, 2, 1, 5, 6, 4, 5, 1, 1, 1, 1, 1, 1,
                1,
            ]),
            blank_tiles: 2,
            rack_size: 7,
            width: 15,
            height: 15,
            bingo_bonus: 50,
            premiums: house_premiums(),
        }
    }

    /// Every edition name the UI's picker can enumerate without duplicating
    /// the list `by_name` matches against.
    pub const EDITION_NAMES: &[&str] =
        &["official", "north_american", "german", "spanish", "spicy"];

    /// Editions that were once offered and no longer are. New games can't be
    /// created under these, but games that already were keep playing under
    /// them forever, so their rules must stay resolvable — see
    /// `by_name_including_retired`.
    pub const RETIRED_EDITION_NAMES: &[&str] = &["wordfeud"];

    /// The edition registry — every bundled ruleset a *new* game can be
    /// created under, looked up by name. `None` for an unrecognized name
    /// (the caller decides whether that's a client error), and deliberately
    /// `None` for a retired edition too: this is the gate on game creation.
    pub fn by_name(name: &str) -> Option<Self> {
        match name {
            "official" => Some(Self::official()),
            "north_american" => Some(Self::north_american()),
            "german" => Some(Self::german()),
            "spanish" => Some(Self::spanish()),
            "spicy" => Some(Self::spicy()),
            _ => None,
        }
    }

    /// `by_name`, plus editions that have been retired from the picker.
    ///
    /// Anything reconstructing an *existing* game's rules from its stored
    /// variant name wants this, not `by_name` — the clients' tile-face
    /// values and move preview, and any engine deciding whether it can play
    /// a given game. The server itself doesn't need it: a game persists its
    /// whole ruleset, so `persistence` reloads the real thing rather than
    /// looking it up by name.
    pub fn by_name_including_retired(name: &str) -> Option<Self> {
        match name {
            "wordfeud" => Some(Self::retired_wordfeud()),
            _ => Self::by_name(name),
        }
    }

    /// A higher-jeopardy English edition: same words, same tiles, same
    /// economy as `official()` — only the board differs. Deliberately its
    /// own edition rather than a board option, because the layout is
    /// bundled into the edition (a game persists its whole ruleset, and
    /// ratings key on the edition name, so this gets its own ladder for
    /// free).
    ///
    /// Everything that makes it spicy is in `spicy_premiums()`. Sharing
    /// `official()`'s tile economy is the point: the two are directly
    /// comparable, and any difference in how games play is attributable to
    /// the board alone.
    fn spicy() -> Self {
        Self {
            name: "spicy".to_string(),
            premiums: spicy_premiums(),
            ..Self::official()
        }
    }

    /// Retired: this was an English edition carrying a second tile economy
    /// (its own letter values, distribution and a 40-point bingo bonus) at a
    /// time when it was the only proof the edition registry could hold more
    /// than one. It was withdrawn once every edition moved to
    /// `house_premiums()` and the project settled on one tile economy per
    /// language — at which point a second English edition named after
    /// somebody else's product had nothing left to justify it.
    ///
    /// Kept, and kept under its original name, purely so games created under
    /// it still resolve; the name is a stored data value now, not an offer.
    /// Delete this once no game references it.
    fn retired_wordfeud() -> Self {
        Self {
            name: "wordfeud".to_string(),
            language: "sowpods".to_string(),
            alphabet: Alphabet::latin26(),
            letter_values: pad::<26>([
                1, 4, 4, 2, 1, 4, 3, 4, 1, 10, 5, 1, 3, 1, 1, 4, 10, 1, 1, 1, 2, 4, 4, 8, 4, 10,
            ]),
            tile_distribution: pad::<26>([
                10, 2, 2, 5, 12, 2, 3, 3, 9, 1, 1, 4, 2, 6, 7, 2, 1, 6, 5, 7, 4, 2, 2, 1, 2, 1,
            ]),
            blank_tiles: 2,
            rack_size: 7,
            width: 15,
            height: 15,
            bingo_bonus: 40,
            premiums: house_premiums(),
        }
    }
}

/// Pads an `N`-value alphabet table (letter values, tile distribution) out
/// to `MAX_ALPHABET_SIZE` — every edition's actual `Alphabet` (not this
/// array's length) is what bounds which slots are ever read, so the tail
/// stays zeroed and unused for any edition with fewer than `MAX_ALPHABET_SIZE`
/// letters.
fn pad<const N: usize>(values: [u8; N]) -> [u8; MAX_ALPHABET_SIZE] {
    let mut padded = [0u8; MAX_ALPHABET_SIZE];
    padded[..N].copy_from_slice(&values);
    padded
}

/// Expands 18 canonical premium-square positions (one symmetric quadrant)
/// into the full 225-cell board via 4-way mirroring — every edition's board
/// is symmetric, so this is shared regardless of which premiums it uses.
/// This project's own board layout, shared by every edition.
///
/// Deliberately not the Scrabble arrangement, and deliberately not
/// Wordfeud's either — both are a specific company's design, and every
/// commercial game of this shape has drawn its own instead. Editions here
/// differ by alphabet, tile distribution, letter values and dictionary,
/// which is the real linguistic difference and nobody's property; the
/// board they are played on is ours.
///
/// Three rules hold it together, and `premium_layout_*` in the tests
/// enforce all of them so a future layout can't quietly break one:
///
/// 1. **Full square symmetry.** Every reflection and rotation of the
///    square maps the board onto itself, so no direction or corner is
///    worth more than another. `mirrored_premiums` only reflects on the
///    two axes, so the diagonal has to be seeded by hand — that's why the
///    off-diagonal entries below appear twice, as `(x, y)` and `(y, x)`.
/// 2. **Big word multipliers stay hard to reach.** Two word multipliers on
///    one line must be far enough apart that combining them costs real
///    tiles: a ×4 needs a 7-cell span and a ×9 needs 9, against official
///    Scrabble's 8. Because the mirror puts a twin of index `i` at `14-i`,
///    that confines every word multiplier to index 0–4, 7 or 10–14 — never
///    5, 6, 8 or 9. Most of the layout follows from this one constraint.
/// 3. **The same scoring weather as the board it replaces.** Identical
///    premium budget (8 TW, 17 DW including the star, 12 TL, 24 DL) and an
///    identical best-case play, so ratings and engine timings carry over
///    rather than restarting against a differently-scoring board.
///
/// The visible result: corners are double words rather than triple, the
/// triple words sit inboard as an octagon, there's no diagonal staircase,
/// and the double letters form a lattice around the star.
fn house_premiums() -> [Premium; 225] {
    mirrored_premiums(&[
        (0, 0, Premium::DoubleWord),
        (2, 0, Premium::TripleLetter),
        (0, 2, Premium::TripleLetter),
        (7, 0, Premium::DoubleWord),
        (0, 7, Premium::DoubleWord),
        (1, 1, Premium::DoubleLetter),
        (3, 1, Premium::TripleWord),
        (1, 3, Premium::TripleWord),
        (4, 2, Premium::DoubleWord),
        (2, 4, Premium::DoubleWord),
        (6, 3, Premium::DoubleLetter),
        (3, 6, Premium::DoubleLetter),
        (6, 4, Premium::DoubleLetter),
        (4, 6, Premium::DoubleLetter),
        (5, 5, Premium::TripleLetter),
        (6, 6, Premium::DoubleLetter),
        (7, 7, Premium::DoubleWord),
    ])
}

/// The high-jeopardy layout. Same construction as `house_premiums`: a
/// top-left quadrant seed, mirrored on both axes, with each `(x, y)` also
/// named as `(y, x)` so the board keeps every symmetry of the square.
///
/// Three deliberate differences from the house board, all of them about
/// *risk* rather than raw scoring:
///
/// 1. **The triple-words sit four apart on their shared line**, at `(5, 2)`
///    and its mirror `(9, 2)`. House keeps its pair eight apart precisely
///    so no single play can ever multiply both; giving that up is the whole
///    point. One five-tile word takes both, at nine times the word score.
/// 2. **A triple-word, double-word and triple-letter sit adjacent** on row
///    5. Three tiles there is a six-times word with a tripled letter —
///    around 138 points for placing three tiles.
/// 3. **The corners are cooled to double-letter.** Pulling heat inboard has
///    to be paid for somewhere, and the rim is where a game spends least of
///    its time.
///
/// What is *not* changed: an opening bingo still tops out at two times,
/// same as house, because every inboard hot spot is off row 7 and column 7.
/// A board that let the first rack score 200 would be swingy in the wrong
/// way — rewarding the luck of a draw rather than the risk of a decision.
///
/// Neither trap is reachable early. Both come alive once play climbs away
/// from the centre, so the danger is what an opponent opens for you.
fn spicy_premiums() -> [Premium; 225] {
    mirrored_premiums(&[
        (0, 0, Premium::DoubleLetter),
        (4, 0, Premium::DoubleLetter),
        (0, 4, Premium::DoubleLetter),
        (7, 0, Premium::DoubleWord),
        (0, 7, Premium::DoubleWord),
        (2, 2, Premium::TripleLetter),
        (5, 2, Premium::TripleWord),
        (2, 5, Premium::TripleWord),
        (5, 3, Premium::DoubleWord),
        (3, 5, Premium::DoubleWord),
        (5, 4, Premium::TripleLetter),
        (4, 5, Premium::TripleLetter),
        (6, 1, Premium::DoubleLetter),
        (1, 6, Premium::DoubleLetter),
        (6, 6, Premium::TripleLetter),
        (7, 7, Premium::DoubleWord),
    ])
}

fn mirrored_premiums(canonical: &[(u8, u8, Premium)]) -> [Premium; 225] {
    let mut premiums = [Premium::Blank; 225];

    for &(x, y, premium) in canonical {
        for (mx, my) in mirror_positions(x, y) {
            premiums[(my as usize) * 15 + (mx as usize)] = premium;
        }
    }

    premiums
}

fn mirror_positions(x: u8, y: u8) -> [(u8, u8); 4] {
    let max = 14;
    [(x, y), (max - x, y), (x, max - y), (max - x, max - y)]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TilePlacement {
    pub offset: u8,
    pub tile: Tile,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveCandidate {
    pub start: Position,
    pub direction: Direction,
    pub tiles: Vec<TilePlacement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossWordPreview {
    pub pos: Position,
    pub word: String,
    pub score: Score,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MovePreview {
    pub legal: bool,
    pub main_word: String,
    pub total_score: Score,
    pub cross_words: Vec<CrossWordPreview>,
    pub error: Option<MoveError>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct MoveScore {
    pub total: Score,
    pub main_word_score: Score,
    pub cross_word_score: Score,
    pub bingo_bonus: Score,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidatedMove {
    pub candidate: MoveCandidate,
    pub preview: MovePreview,
    pub score: MoveScore,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum MoveError {
    InvalidMove,
    /// One or more words formed by this placement — the main word and/or
    /// any cross words — aren't in the dictionary. Always at least one
    /// entry; the main word (if invalid) comes first.
    InvalidWord(Vec<String>),
    InvalidPosition,
    InvalidDirection,
    TilesDoNotFit,
    TilesDoNotConnect,
    /// The opening play placed a single tile. Scrabble requires the first
    /// word to combine two or more tiles across the start square, so one
    /// tile is illegal however the board is later read.
    ///
    /// Until this existed the rule was enforced by accident: a lone tile's
    /// main word is one character long, and no word list we ship contains
    /// a single-character entry, so the dictionary rejected it. That is a
    /// coincidence of the data rather than a rule, and it reported the
    /// wrong reason — a list that did contain a one-letter word (Spanish
    /// *y* and *o* are real words, just absent from our list) would have
    /// made single-tile openings legal.
    OpeningMoveTooShort,
}

#[cfg(test)]
mod tests {
    use super::{
        Direction, Letter, LetterMask, Position, Premium, Rack, Tile, VariantRules, mask_contains,
        mask_insert, mask_is_empty, mask_remove,
    };
    use std::str::FromStr;

    fn every_edition() -> Vec<VariantRules> {
        vec![
            VariantRules::official(),
            VariantRules::north_american(),
            VariantRules::german(),
            VariantRules::spanish(),
        ]
    }

    fn premium_at(rules: &VariantRules, x: usize, y: usize) -> Premium {
        rules.premiums[y * 15 + x]
    }

    /// The spicy board's whole reason to exist is a raised ceiling, so the
    /// properties that make it spicy are worth pinning: a later tidy-up
    /// that "fixed" the close-together triple-words would silently turn it
    /// back into the house board with extra steps.
    #[test]
    fn spicy_board_keeps_its_jeopardy_and_its_flat_opening() {
        let spicy = VariantRules::by_name("spicy").expect("spicy is in the registry");
        let house = VariantRules::official();

        let multiplier = |rules: &VariantRules, span: usize, row: Option<usize>| {
            let mut best = 1u32;
            let rows: Vec<usize> = match row {
                Some(y) => vec![y],
                None => (0..15).collect(),
            };
            for y in rows {
                for x in 0..=(15 - span) {
                    let product: u32 = (0..span)
                        .map(|i| match rules.premiums[y * 15 + x + i] {
                            Premium::DoubleWord => 2,
                            Premium::TripleWord => 3,
                            _ => 1,
                        })
                        .product();
                    best = best.max(product);
                }
            }
            best
        };

        // The trap: two triple-words within a five-tile reach of each other.
        assert_eq!(
            multiplier(&spicy, 5, None),
            9,
            "spicy should allow a 9x five-tile line"
        );
        assert_eq!(
            multiplier(&house, 5, None),
            3,
            "house deliberately does not"
        );

        // But the opening is held flat: every inboard hot spot is off the
        // centre lines, so the first rack cannot cash in on luck alone.
        assert_eq!(
            multiplier(&spicy, 7, Some(7)),
            2,
            "opening row must stay 2x"
        );
        assert_eq!(multiplier(&house, 7, Some(7)), 2);

        // Same words, same tiles — only the board differs, so the two
        // editions stay directly comparable.
        assert_eq!(spicy.language, house.language);
        assert_eq!(spicy.letter_values, house.letter_values);
        assert_eq!(spicy.tile_distribution, house.tile_distribution);
        assert_eq!(spicy.bingo_bonus, house.bingo_bonus);
        assert_ne!(spicy.premiums, house.premiums);
    }

    /// Rule 1 of `house_premiums`. `mirrored_premiums` only reflects on the
    /// two axes, so diagonal symmetry depends entirely on the seed list
    /// naming both `(x, y)` and `(y, x)` — an easy thing to forget, and
    /// invisible unless something checks. Without it one direction of play
    /// is worth more than the other.
    #[test]
    fn premium_layout_has_every_symmetry_of_the_square() {
        for rules in every_edition() {
            for y in 0..15 {
                for x in 0..15 {
                    let cell = premium_at(&rules, x, y);
                    assert_eq!(cell, premium_at(&rules, 14 - x, y), "{} h-flip", rules.name);
                    assert_eq!(cell, premium_at(&rules, x, 14 - y), "{} v-flip", rules.name);
                    assert_eq!(cell, premium_at(&rules, y, x), "{} transpose", rules.name);
                    assert_eq!(
                        cell,
                        premium_at(&rules, 14 - y, 14 - x),
                        "{} anti-transpose",
                        rules.name
                    );
                }
            }
        }
    }

    /// Rule 2 of `house_premiums`: combining word multipliers has to cost
    /// tiles. A ×4 must need a 7-cell span and a ×9 a 9-cell one, so
    /// neither is reachable with a casual short word. The first draft of
    /// this layout put two double words three cells apart, handing out a
    /// ×4 for three tiles — this is the check that would have caught it.
    #[test]
    fn premium_layout_keeps_big_word_multipliers_expensive() {
        for rules in every_edition() {
            let mut lines: Vec<Vec<Premium>> = Vec::new();
            for y in 0..15 {
                lines.push((0..15).map(|x| premium_at(&rules, x, y)).collect());
            }
            for x in 0..15 {
                lines.push((0..15).map(|y| premium_at(&rules, x, y)).collect());
            }

            for line in &lines {
                let multipliers: Vec<(usize, u32)> = line
                    .iter()
                    .enumerate()
                    .filter(|(_, premium)| premium.word_multiplier() > 1)
                    .map(|(index, premium)| (index, premium.word_multiplier() as u32))
                    .collect();
                for (i, (left, left_mult)) in multipliers.iter().enumerate() {
                    for (right, right_mult) in &multipliers[i + 1..] {
                        let span = right - left + 1;
                        let combined = left_mult * right_mult;
                        let required = if combined >= 9 { 9 } else { 7 };
                        assert!(
                            span >= required,
                            "{}: x{combined} available across only {span} cells",
                            rules.name
                        );
                    }
                }
            }
        }
    }

    /// Rule 3: the premium budget every edition is balanced against. A
    /// layout that quietly gained or lost premium squares would shift the
    /// scoring band the ratings and engine timings were measured on.
    #[test]
    fn premium_layout_spends_the_same_budget_in_every_edition() {
        for rules in every_edition() {
            let count = |wanted: Premium| {
                rules
                    .premiums
                    .iter()
                    .filter(|premium| **premium == wanted)
                    .count()
            };
            assert_eq!(count(Premium::TripleWord), 8, "{} TW", rules.name);
            assert_eq!(count(Premium::DoubleWord), 17, "{} DW", rules.name);
            assert_eq!(count(Premium::TripleLetter), 12, "{} TL", rules.name);
            assert_eq!(count(Premium::DoubleLetter), 24, "{} DL", rules.name);
            assert_eq!(
                premium_at(&rules, 7, 7),
                Premium::DoubleWord,
                "{} centre star",
                rules.name
            );
        }
    }

    #[test]
    fn parse_position() {
        let pos = Position::from_str("H8").unwrap();
        assert_eq!(pos, Position::new(7, 7));
    }

    #[test]
    fn rack_deserializes_a_pre_widening_26_count_snapshot() {
        // Regression test: `Rack.counts` widened from [u8;26] to
        // [u8;MAX_ALPHABET_SIZE] — a rack persisted before that change is
        // exactly this 26-element JSON shape, and must still load instead
        // of every pre-existing saved game failing at startup.
        let json = r#"{"counts":[1,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"blanks":1}"#;
        let rack: Rack = serde_json::from_str(json).expect("old 26-count rack should still parse");
        assert_eq!(rack.counts[0], 1);
        assert_eq!(rack.counts[2], 2);
        assert_eq!(rack.blanks, 1);
        assert!(rack.counts[26..].iter().all(|&count| count == 0));
    }

    #[test]
    fn rack_round_trips_a_full_64_count_snapshot() {
        let mut rack = Rack::default();
        rack.add_letter(Letter::from(30u8));
        let json = serde_json::to_string(&rack).expect("rack should serialize");
        let restored: Rack = serde_json::from_str(&json).expect("rack should round-trip");
        assert_eq!(restored, rack);
    }

    #[test]
    fn step_position() {
        let pos = Position::new(7, 7);
        assert_eq!(
            pos.try_step_forward(Direction::Horizontal, 15, 15),
            Some(Position::new(8, 7))
        );
        assert_eq!(
            pos.try_step_backward(Direction::Vertical),
            Some(Position::new(7, 6))
        );
    }

    #[test]
    fn letter_to_char() {
        assert_eq!(Letter::from('A').as_char(), 'A');
        assert_eq!(Letter::from('Z').as_usize(), 25);
    }

    #[test]
    fn letter_mask_helpers() {
        let mut mask: LetterMask = 0;
        assert!(mask_is_empty(mask));
        mask_insert(&mut mask, Letter::from('C'));
        assert!(mask_contains(mask, Letter::from('C')));
        mask_remove(&mut mask, Letter::from('C'));
        assert!(mask_is_empty(mask));
    }

    #[test]
    fn rack_consumes_tiles() {
        let mut rack = Rack {
            blanks: 1,
            ..Rack::default()
        };
        rack.add_letter(Letter::from('A'));

        assert!(rack.consume_tile(Tile::Letter(Letter::from('A'))));
        assert!(rack.consume_tile(Tile::Blank {
            acting_as: Some(Letter::from('B')),
        }));
        assert!(!rack.consume_tile(Tile::Letter(Letter::from('Z'))));
    }

    /// Every edition bundles its own economics rather than deferring to a
    /// shared default, so no two are wholly interchangeable. `official` and
    /// `north_american` deliberately carry identical letter values and tile
    /// distributions (see `north_american`'s doc comment) — they're
    /// separated by dictionary alone, which is exactly why this checks for
    /// difference in *some* field rather than in the economics specifically.
    #[test]
    fn no_two_editions_are_interchangeable() {
        let editions = every_edition();
        for (i, a) in editions.iter().enumerate() {
            for b in &editions[i + 1..] {
                assert_ne!(a.name, b.name, "edition names must be unique");
                assert!(
                    a.language != b.language
                        || a.alphabet != b.alphabet
                        || a.letter_values != b.letter_values
                        || a.tile_distribution != b.tile_distribution
                        || a.bingo_bonus != b.bingo_bonus,
                    "{} and {} differ in name only — one of them is redundant",
                    a.name,
                    b.name
                );
            }
        }
    }

    #[test]
    fn by_name_resolves_known_editions_and_rejects_unknown_ones() {
        assert_eq!(VariantRules::by_name("official").unwrap().name, "official");
        assert_eq!(VariantRules::by_name("spanish").unwrap().name, "spanish");
        assert!(VariantRules::EDITION_NAMES.contains(&"spanish"));
        assert!(VariantRules::by_name("not-a-real-edition").is_none());
        // Retired: games created under it keep their own persisted copy of
        // the rules, but no new game can be created with it.
        assert!(VariantRules::by_name("wordfeud").is_none());
        assert!(!VariantRules::EDITION_NAMES.contains(&"wordfeud"));
    }

    #[test]
    fn every_editions_premiums_are_still_a_symmetric_15x15_board() {
        for rules in every_edition() {
            assert_eq!(rules.premiums.len(), 225);
            for y in 0..15u8 {
                for x in 0..15u8 {
                    let mirrored = rules.premiums[(y as usize) * 15 + (14 - x) as usize];
                    let original = rules.premiums[(y as usize) * 15 + x as usize];
                    assert_eq!(
                        mirrored, original,
                        "{}'s premiums should be left/right symmetric at ({x}, {y})",
                        rules.name
                    );
                }
            }
        }
    }
}
