//! Data types for the tiered arena dictionary.
//!
//! This is the storage layout `WordListDictionary` is being replaced by,
//! landing in pieces: the types and their packing first, construction and
//! lookup after. Nothing here is wired into `Dictionary` yet, so the
//! existing implementation remains the one in use.
//!
//! Shape, from the top:
//!
//! - **the arena** — every word as a run of `Letter` bytes in one
//!   allocation, with an offset table, so letter *d* of word *i* is an
//!   indexed read rather than a pointer chase.
//! - **a dense table** over the first *two* characters, addressed
//!   arithmetically as `l0 × n + l1`. There is deliberately no one-letter
//!   tier: nothing ever asks a question about a one-character prefix,
//!   because every letter starts some word and one-letter words are
//!   illegal (Scrabble's opening play needs two tiles, and no list we
//!   ship contains a single-character entry).
//! - **a sparse index** below it, holding only prefixes that exist, and
//!   only while a group is bigger than `MAX_LEAF_WORDS`. Below that it
//!   is a leaf and the arena is searched directly.
//!
//! The measurements behind the field widths are in
//! `examples/sparse_budget.rs`.

use crate::model::Alphabet;

/// The largest group left unindexed: above this many words a group keeps a
/// child index, at or below it the group becomes a leaf and the arena is
/// searched directly. So it is also the most words a single leaf can
/// cover, which is what ties it to [`PackedChild::MAX_LEAF_LEN`].
///
/// A **memory** budget: every index entry has to earn its 5 bytes, and
/// pruning here is what stops the deep tail of tiny nodes that makes a
/// full trie expensive. Lowering it costs Spanish 4x the edges for one
/// halving of the range; 64 is the knee. Measured by
/// `examples/sparse_budget.rs`.
pub const MAX_LEAF_WORDS: usize = 64;

/// At or below this many words, scan the arena forward instead of
/// bisecting it: consecutive words are adjacent, so a short scan is
/// sequential and prefetchable where a bisect jumps.
///
/// A **cache** budget, and deliberately a separate constant from
/// [`MAX_LEAF_WORDS`] even though both are "small enough". That one
/// decides what gets *stored*, this one decides how what is stored gets
/// *searched*; they are set by different measurements and there is no
/// reason they should coincide. Note the bisect path only exists while
/// this is strictly below `MAX_LEAF_WORDS` — setting them equal means
/// every leaf is scanned and nothing is ever bisected.
pub const MAX_SCAN_WORDS: usize = 32;

const _: () = assert!(
    MAX_LEAF_WORDS <= PackedChild::MAX_LEAF_LEN,
    "MAX_LEAF_WORDS must fit PackedChild's len field"
);
const _: () = assert!(
    MAX_SCAN_WORDS <= MAX_LEAF_WORDS,
    "a scan cutoff above the leaf cutoff would never be reached"
);

/// Every shipped list has to fit [`PackedChild`]'s fields, and the widths were
/// chosen against the counts in `examples/sparse_budget.rs` rather than
/// against SOWPODS alone — German and Spanish are both ~600k words and
/// are what actually bound the design. Asserted at compile time, with a
/// 3× margin, so narrowing a field to save a bit fails the build here
/// rather than as a panic in `Child::pack` on one particular word list.
const _: () = {
    assert!(
        151_804 * 3 < PackedChild::MAX_EDGES,
        "spanish at the tightest cutoff, worst edges"
    );
    assert!(
        635_090 * 3 < PackedChild::MAX_WORDS,
        "spanish, worst word count"
    );
    assert!(28 <= PackedChild::MAX_FANOUT, "german, widest node");
};

/// What an edge points at: where the words under this prefix live, how
/// many there are, and whether the prefix is itself a word.
///
/// This is the form all logic works in. [`PackedChild`] is the same thing
/// squeezed into 32 bits for storage, and the only places that name it are
/// the arrays and the two conversions — everything else unpacks once and
/// deals in this enum.
///
/// `is_word` sits on the **edge** rather than on the node it points at:
/// CAT is a word, and the sibling scan that located T has already produced
/// the index that answers it, so the load fetching the pointer answers
/// this at the same time. [`Empty`](Child::Empty) has no `is_word` because
/// it has no prefix to ask about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Child {
    /// No word has this prefix. Only ever produced by the dense table —
    /// in the sparse arrays absence is the letter not appearing in the
    /// node's letter run at all.
    Empty,
    /// The group is indexed: `fanout` edges starting at `start` in the
    /// sparse arrays.
    Index {
        start: u32,
        fanout: u8,
        is_word: bool,
    },
    /// The group was at or below [`MAX_LEAF_WORDS`] at construction, so it
    /// was left unindexed: `len` words starting at word index `from`.
    Leaf { from: u32, len: u8, is_word: bool },
}

impl Child {
    /// Squeezes this into its stored form.
    ///
    /// An inherent method rather than a `From` impl because it validates
    /// and panics: a `From` that can panic is a trap at call sites that
    /// look infallible. Construction runs once per dictionary, so the
    /// checks are free where they matter.
    ///
    /// # Panics
    /// If any field exceeds what its bits can hold, or if a length is
    /// zero. Both are construction bugs, and failing loudly beats
    /// truncating into a pointer that decodes to something plausible.
    pub fn pack(self) -> PackedChild {
        match self {
            Child::Empty => PackedChild::EMPTY,
            Child::Index {
                start,
                fanout,
                is_word,
            } => {
                assert!(
                    fanout as usize <= PackedChild::MAX_FANOUT,
                    "fan-out {fanout} overflows PackedChild"
                );
                assert!(
                    (start as usize) < PackedChild::MAX_EDGES,
                    "edge index {start} overflows PackedChild"
                );
                // Unbiased on purpose: a zero length is what makes the
                // all-zero word mean Empty, so it must stay unreachable
                // for a real entry.
                assert!(fanout > 0, "an indexed group has at least one child");
                PackedChild(
                    ((is_word as u32) << PackedChild::IS_WORD_SHIFT)
                        | ((fanout as u32) << PackedChild::INDEX_START_BITS)
                        | start,
                )
            }
            Child::Leaf { from, len, is_word } => {
                assert!(
                    len as usize <= PackedChild::MAX_LEAF_LEN,
                    "leaf length {len} overflows PackedChild"
                );
                assert!(
                    (from as usize) < PackedChild::MAX_WORDS,
                    "word index {from} overflows PackedChild"
                );
                assert!(len > 0, "a leaf covers at least one word");
                PackedChild(
                    (PackedChild::KIND_LEAF << PackedChild::KIND_SHIFT)
                        | ((is_word as u32) << PackedChild::IS_WORD_SHIFT)
                        | ((len as u32) << PackedChild::LEAF_START_BITS)
                        | from,
                )
            }
        }
    }

    /// Whether the prefix ending at this edge is itself a word. `false` for
    /// [`Empty`](Child::Empty), which has no prefix.
    #[inline]
    pub fn is_word(self) -> bool {
        match self {
            Child::Empty => false,
            Child::Index { is_word, .. }
            | Child::Leaf {
                from: _,
                len: _,
                is_word,
            } => is_word,
        }
    }
}

/// A [`Child`] in its stored form: one 32-bit word.
///
/// Purely a storage concern — nothing reasons about a `PackedChild`, it is
/// read out of an array and immediately [`unpack`](PackedChild::unpack)ed.
/// It exists as a distinct type rather than a bare `u32` so that the
/// child arrays cannot be confused with the offset arrays beside them,
/// which are also `u32` and mean something entirely different.
///
/// ```text
///     31         30           29 …          22 | 21 … 0
///  ┌────────────┬─────────────┬───────────────────────────┐
///  │ kind (1)   │ is_word (1) │ len (7|8) │ start (23|22) │
///  └────────────┴─────────────┴───────────────────────────┘
///     0 = Index                 1..127        edge index
///     1 = Leaf                  1..255        word index
/// ```
///
/// **`Empty` needs no tag of its own**: a length of zero is impossible for
/// either variant — an indexed node has at least one child, a leaf covers
/// at least one word — so the all-zero word is unambiguously empty and
/// nothing else. The kind bit is only ever consulted once a slot is known
/// to be occupied.
///
/// That is what makes a zeroed allocation a table of empty slots, so
/// `vec![PackedChild::EMPTY; n²]` is a `memset` and a construction bug
/// that skips a slot reads as "no such prefix" rather than as a valid
/// pointer at entry 0. It relies on the lengths being stored
/// **unbiased**: storing `len - 1` to win one more value would make the
/// all-zero word decode as a real one-element node, and would cost the
/// spare bit to fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(transparent)]
pub struct PackedChild(u32);

impl PackedChild {
    const KIND_SHIFT: u32 = 31;
    const IS_WORD_SHIFT: u32 = 30;

    const KIND_LEAF: u32 = 1;

    // Index: 7 bits of fan-out (bounded by MAX_ALPHABET_SIZE), 23 of start.
    const INDEX_LEN_BITS: u32 = 7;
    const INDEX_START_BITS: u32 = 23;
    // Leaf: 8 bits of length (bounded by MAX_LEAF_WORDS), 22 of word index.
    const LEAF_LEN_BITS: u32 = 8;
    const LEAF_START_BITS: u32 = 22;

    /// Largest fan-out a node may have. Bounded by `MAX_ALPHABET_SIZE`
    /// rather than by the field; the widest node measured is 28.
    pub const MAX_FANOUT: usize = (1 << Self::INDEX_LEN_BITS) - 1;
    /// Field capacity for a leaf's length, which is what bounds
    /// [`MAX_LEAF_WORDS`]. The *chosen* cutoff is that constant; this is
    /// only how much the bits allow.
    pub const MAX_LEAF_LEN: usize = (1 << Self::LEAF_LEN_BITS) - 1;
    /// Largest addressable sparse-edge array. Worst measured is 151,804
    /// (Spanish at the tightest cutoff swept).
    pub const MAX_EDGES: usize = 1 << Self::INDEX_START_BITS;
    /// Largest addressable word list. Worst measured is 635,090 (Spanish).
    pub const MAX_WORDS: usize = 1 << Self::LEAF_START_BITS;

    const _LAYOUT: () = {
        assert!(1 + 1 + Self::INDEX_LEN_BITS + Self::INDEX_START_BITS == 32);
        assert!(1 + 1 + Self::LEAF_LEN_BITS + Self::LEAF_START_BITS == 32);
        assert!(Self::MAX_FANOUT >= crate::model::MAX_ALPHABET_SIZE);
    };

    /// The empty slot. Equal to `PackedChild(0)`, so a zeroed allocation
    /// is already a table of empty slots.
    pub const EMPTY: Self = Self(0);

    /// Decodes into the form logic works in.
    ///
    /// Empty is tested first and by value, because a zero length can only
    /// mean empty — the kind bit is meaningless until that is ruled out.
    /// With this inlined the [`Child`] never reaches memory: it stays in
    /// registers and the caller's `match` folds into the branch this
    /// already needed.
    #[inline]
    pub fn unpack(self) -> Child {
        if self.is_empty() {
            Child::Empty
        } else if self.0 >> Self::KIND_SHIFT == Self::KIND_LEAF {
            Child::Leaf {
                from: self.0 & ((1 << Self::LEAF_START_BITS) - 1),
                len: ((self.0 >> Self::LEAF_START_BITS) & ((1 << Self::LEAF_LEN_BITS) - 1)) as u8,
                is_word: self.is_word_bit(),
            }
        } else {
            Child::Index {
                start: self.0 & ((1 << Self::INDEX_START_BITS) - 1),
                fanout: ((self.0 >> Self::INDEX_START_BITS) & ((1 << Self::INDEX_LEN_BITS) - 1))
                    as u8,
                is_word: self.is_word_bit(),
            }
        }
    }

    /// The one field readable without unpacking, kept because a scan can
    /// answer "is what I just spelled a word" from the pointer it already
    /// loaded, without decoding the rest.
    #[inline]
    pub fn is_word(self) -> bool {
        !self.is_empty() && self.is_word_bit()
    }

    #[inline]
    fn is_word_bit(self) -> bool {
        self.0 & (1 << Self::IS_WORD_SHIFT) != 0
    }

    #[inline]
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

/// A position part-way through spelling a word, handed back by `advance`
/// and passed into the next call.
///
/// Each variant is one regime of the walk, and the payloads are the
/// *(length, start)* pairs a [`Child`] already carries, kept unpacked so the
/// hot path doesn't re-decode them.
///
/// `depth` counts *characters*, not tiles: a digraph tile advances it by
/// more than one, which is what makes both tilings of Spanish CH reach
/// the same entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cursor {
    /// Nothing spelled yet.
    Start,
    /// One character seen. Nothing is resolved and nothing needs to be —
    /// every letter starts some word, so there is no prune signal to
    /// give, and a one-character word cannot be legal.
    First(u8),
    /// Inside the sparse index: `fanout` edges from `start`.
    Node { start: u32, fanout: u8, depth: u8 },
    /// A word range in the arena: bisect it above [`MAX_SCAN_WORDS`],
    /// scan it below.
    Range { from: u32, len: u8, depth: u8 },
}

/// The result of advancing one letter: where we are now, and whether what
/// has been spelled is a word. Returned as `Option<Step>` — `None` *is*
/// "no word continues with this", the prune signal — so a cursor that
/// isn't valid can't be used by mistake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Step {
    pub cursor: Cursor,
    pub is_word: bool,
}

// ---------------------------------------------------------------------------
// The dictionary
// ---------------------------------------------------------------------------

/// A [`TieredDictionary`] walk, as the `Dictionary` trait wants it: a
/// self-contained cursor that can advance without being handed the
/// dictionary again.
///
/// `Copy` and 16 bytes — the [`Cursor`] plus one reference — because move
/// generation stores and passes one per candidate branch.
#[derive(Debug, Clone, Copy)]
pub struct TieredCursor<'a> {
    dictionary: &'a TieredDictionary,
    cursor: Cursor,
    is_word: bool,
}

impl<'a> TieredCursor<'a> {
    /// True if the prefix spelled so far is itself a word.
    ///
    /// Tracked on the cursor rather than recomputed, because the packed
    /// child that `advance` already read carries the answer — see
    /// [`Child`]. Move generation does not currently ask, but the
    /// cross-check path does.
    pub fn is_word(&self) -> bool {
        self.is_word
    }
}

impl crate::dictionary::PrefixCursor for TieredCursor<'_> {
    fn advance(&self, letter: crate::model::Letter, _alphabet: &Alphabet) -> Option<Self> {
        // `_alphabet` is unused on purpose: the grapheme expansion is baked
        // into the dictionary at construction, so a digraph resolves
        // without the caller's alphabet and without `to_letter`'s linear
        // scan on the hot path.
        let step = self.dictionary.advance(self.cursor, letter.0)?;
        Some(Self {
            dictionary: self.dictionary,
            cursor: step.cursor,
            is_word: step.is_word,
        })
    }
}

impl crate::dictionary::Dictionary for TieredDictionary {
    fn is_word(&self, word: &str) -> bool {
        let mut buffer = [0u8; 4];
        let mut letters = [0u8; 64];
        let mut count = 0usize;
        for ch in word.chars() {
            let Some(letter) = self.alphabet.to_letter(ch.encode_utf8(&mut buffer)) else {
                return false;
            };
            if count == letters.len() {
                return false;
            }
            letters[count] = letter.0;
            count += 1;
        }
        self.contains(&letters[..count])
    }

    type Cursor<'a>
        = TieredCursor<'a>
    where
        Self: 'a;

    fn root_cursor(&self) -> Self::Cursor<'_> {
        TieredCursor {
            dictionary: self,
            cursor: self.root(),
            is_word: false,
        }
    }

    /// Walks the shared prefix once, then spends one `advance` per
    /// candidate letter before checking the suffix.
    ///
    /// Two savings over the default, and the smaller one is the speed.
    /// The default builds a `String` per candidate — an allocation per
    /// letter per square, which for a board's worth of cross-checks is
    /// thousands of allocations that produce nothing but a hash key. This
    /// allocates nothing at all.
    ///
    /// It also prunes early: most letters fail on the very first step
    /// after the prefix, and those cost one array read rather than a full
    /// candidate word. Measured at 2-3x the default when there is a prefix
    /// to hoist, and level with it when the square is at the start of the
    /// cross word — where there is no shared prefix, and only the saved
    /// allocation is left.
    fn allowed_letters(
        &self,
        before: &[crate::model::Letter],
        after: &[crate::model::Letter],
        _alphabet: &Alphabet,
    ) -> crate::model::LetterMask {
        let mut mask = 0;
        // The shared prefix, walked once. If it is already a dead end no
        // letter can work — which happens on a board holding a word this
        // dictionary doesn't contain, so it must not panic.
        let mut prefix = self.root();
        for existing in before {
            match self.advance(prefix, existing.0) {
                Some(step) => prefix = step.cursor,
                None => return mask,
            }
        }

        for index in 0..self.alphabet_len as u8 {
            let Some(step) = self.advance(prefix, index) else {
                continue;
            };
            let mut cursor = step.cursor;
            let mut is_word = step.is_word;
            let mut alive = true;
            for existing in after {
                match self.advance(cursor, existing.0) {
                    Some(step) => {
                        cursor = step.cursor;
                        is_word = step.is_word;
                    }
                    None => {
                        alive = false;
                        break;
                    }
                }
            }
            // A one-character cross word cannot be legal, and `advance`
            // deliberately reports nothing about depth 1 — so require a
            // real word of at least two characters, which `before` and
            // `after` being empty together already rules out at the caller.
            if alive && is_word {
                crate::model::mask_insert(&mut mask, crate::model::Letter(index));
            }
        }
        mask
    }
}

/// The tiered arena dictionary: a sorted word arena, a dense table over the
/// first two characters, and a size-pruned sparse index below it.
///
/// Words are ordered by **letter sequence**, not by string — an alphabet's
/// order is its own, and Spanish files Ñ between N and O where its code
/// point would sort after Z. Every comparison here is on `Letter` bytes, so
/// that ordering is inherent rather than something to remember.
#[derive(Debug)]
pub struct TieredDictionary {
    /// Every word's letters end to end. Word *i* is
    /// `letters[offsets[i]..offsets[i + 1]]`.
    letters: Box<[u8]>,
    offsets: Box<[u32]>,
    /// `alphabet_len²` slots, addressed as `l0 × alphabet_len + l1`.
    dense: Box<[PackedChild]>,
    /// The sparse index, as two parallel arrays sliced by a parent's
    /// `(start, fanout)`. `edge_letters` is the scan target — contiguous
    /// bytes — and `edge_children` is read once at the matched position.
    edge_letters: Box<[u8]>,
    edge_children: Box<[PackedChild]>,
    alphabet_len: usize,
    /// Kept so `is_word(&str)` can map characters to letters. `Letter`'s
    /// `From<char>` cannot be used for that: it is `ch as u8 - b'A'`, which
    /// is only correct for an alphabet whose order happens to be ASCII —
    /// silently wrong for Spanish, where Ñ is index 13, and for German.
    alphabet: Alphabet,
    /// How each tile's `Letter` expands into the single-character letters
    /// the arena is built from. Baked in at construction so `advance` never
    /// needs the alphabet, and never pays `to_letter`'s linear scan on the
    /// hot path.
    expansion: Box<[Expansion]>,
}

/// A `Letter`'s characters, as indices of single-character letters.
///
/// Two is the maximum by *type*: [`Grapheme`](crate::model::Grapheme) is
/// `Single | Double`, so this cannot silently truncate a longer one.
#[derive(Debug, Clone, Copy)]
struct Expansion {
    chars: [u8; 2],
    len: u8,
}

impl TieredDictionary {
    /// Builds from words already encoded as `Letter` byte runs. They need
    /// not be sorted or unique; this sorts and dedups them.
    ///
    /// Words shorter than two characters are **dropped**: the structure is
    /// addressed from a two-character dense table, and a one-letter word
    /// cannot be legal anyway (Scrabble's opening play needs two tiles, and
    /// no list we ship has a single-character entry). Dropping rather than
    /// rejecting keeps a malformed list from taking the process down.
    /// Builds from word-list text, encoding each word **character by
    /// character** — so a Spanish word written with "ch" is stored as C
    /// then H, and a CH tile reaches it by expanding to the same two. That
    /// is what makes both tilings of the same word find the same entry.
    /// Words containing anything outside the alphabet are dropped.
    pub fn from_word_list(text: &str, alphabet: &Alphabet) -> Self {
        let mut buffer = [0u8; 4];
        let words = text
            .split_whitespace()
            .filter_map(|word| {
                word.chars()
                    .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).map(|l| l.0))
                    .collect::<Option<Vec<u8>>>()
            })
            .collect();
        Self::from_encoded(words, alphabet)
    }

    pub fn from_encoded(mut words: Vec<Vec<u8>>, alphabet: &Alphabet) -> Self {
        let alphabet_len = alphabet.len();
        words.retain(|word| word.len() >= 2);
        words.sort_unstable();
        words.dedup();

        assert!(
            words.len() <= PackedChild::MAX_WORDS,
            "{} words exceeds PackedChild's {} addressable",
            words.len(),
            PackedChild::MAX_WORDS
        );

        // --- arena ---------------------------------------------------
        let total: usize = words.iter().map(Vec::len).sum();
        let mut letters = Vec::with_capacity(total);
        let mut offsets = Vec::with_capacity(words.len() + 1);
        offsets.push(0u32);
        for word in &words {
            letters.extend_from_slice(word);
            offsets.push(letters.len() as u32);
        }

        // --- dense table, then the sparse index breadth-first ---------
        //
        // Breadth-first so that a node's edges are contiguous and siblings
        // of the same depth land near each other: the scan reads one run,
        // and the runs a walk touches in sequence are at least in the same
        // region rather than scattered by insertion order.
        let mut dense = vec![PackedChild::EMPTY; alphabet_len * alphabet_len];
        let mut edge_letters: Vec<u8> = Vec::new();
        let mut edge_children: Vec<PackedChild> = Vec::new();

        // Groups awaiting an index node, in the order their edges will be
        // written. A node's fan-out and start aren't known until its edges
        // exist, so each records where its parent's pointer lives so it can
        // be filled in afterwards.
        enum Patch {
            Dense(usize),
            Edge(usize),
        }
        let mut queue: Vec<(usize, usize, usize, Patch)> = Vec::new();

        let mut i = 0;
        while i < words.len() {
            let (l0, l1) = (words[i][0], words[i][1]);
            let mut j = i;
            while j < words.len() && words[j][0] == l0 && words[j][1] == l1 {
                j += 1;
            }
            let slot = l0 as usize * alphabet_len + l1 as usize;
            let is_word = words[i].len() == 2;
            if j - i > MAX_LEAF_WORDS {
                queue.push((i, j, 2, Patch::Dense(slot)));
            } else {
                dense[slot] = Child::Leaf {
                    from: i as u32,
                    len: (j - i) as u8,
                    is_word,
                }
                .pack();
            }
            i = j;
        }

        // Walk the queue, writing each node's edge run and patching the
        // parent that pointed at it.
        let mut head = 0;
        while head < queue.len() {
            let (lo, hi, depth) = (queue[head].0, queue[head].1, queue[head].2);
            head += 1;

            let start = edge_children.len();
            let mut fanout = 0u8;
            let mut k = lo;
            // Children of this group: one edge per distinct letter at
            // `depth`. Words ending exactly here carry no edge — they are
            // recorded by the parent's is_word bit, already written.
            while k < hi {
                if words[k].len() <= depth {
                    k += 1;
                    continue;
                }
                let letter = words[k][depth];
                let mut m = k;
                while m < hi && words[m].len() > depth && words[m][depth] == letter {
                    m += 1;
                }
                let child_is_word = words[k].len() == depth + 1;
                edge_letters.push(letter);
                if m - k > MAX_LEAF_WORDS {
                    let slot = edge_children.len();
                    edge_children.push(PackedChild::EMPTY);
                    queue.push((k, m, depth + 1, Patch::Edge(slot)));
                } else {
                    edge_children.push(
                        Child::Leaf {
                            from: k as u32,
                            len: (m - k) as u8,
                            is_word: child_is_word,
                        }
                        .pack(),
                    );
                }
                fanout += 1;
                k = m;
            }

            let is_word = words[lo].len() == depth;
            let packed = Child::Index {
                start: start as u32,
                fanout,
                is_word,
            }
            .pack();
            match queue[head - 1].3 {
                Patch::Dense(slot) => dense[slot] = packed,
                Patch::Edge(slot) => edge_children[slot] = packed,
            }
        }

        assert!(
            edge_children.len() <= PackedChild::MAX_EDGES,
            "{} edges exceeds PackedChild's {} addressable",
            edge_children.len(),
            PackedChild::MAX_EDGES
        );

        // A digraph's characters have to be letters in their own right,
        // since the arena is built from single characters. Checked once
        // here rather than assumed: an alphabet that broke it would
        // otherwise make every word containing the digraph unreachable.
        let mut buffer = [0u8; 4];
        let expansion: Vec<Expansion> = (0..alphabet_len)
            .map(|index| {
                let grapheme = alphabet
                    .to_grapheme(crate::model::Letter(index as u8))
                    .expect("index is within the alphabet");
                let mut chars = [0u8; 2];
                let mut len = 0u8;
                for ch in grapheme.chars() {
                    let single = alphabet
                        .to_letter(ch.encode_utf8(&mut buffer))
                        .unwrap_or_else(|| {
                            panic!(
                                "{grapheme} contains {ch:?}, which is not itself a letter of \
                                 this alphabet — the arena is built from single characters, \
                                 so no word containing it could be reached"
                            )
                        });
                    chars[len as usize] = single.0;
                    len += 1;
                }
                Expansion { chars, len }
            })
            .collect();

        Self {
            letters: letters.into_boxed_slice(),
            offsets: offsets.into_boxed_slice(),
            dense: dense.into_boxed_slice(),
            edge_letters: edge_letters.into_boxed_slice(),
            edge_children: edge_children.into_boxed_slice(),
            alphabet_len,
            alphabet: alphabet.clone(),
            expansion: expansion.into_boxed_slice(),
        }
    }

    /// Bytes held beyond the word-list text, which is compiled in and paid
    /// for once regardless.
    pub fn resident_bytes(&self) -> usize {
        self.letters.len()
            + self.offsets.len() * 4
            + self.dense.len() * 4
            + self.edge_letters.len()
            + self.edge_children.len() * 4
    }

    pub fn word_count(&self) -> usize {
        self.offsets.len() - 1
    }

    pub fn edge_count(&self) -> usize {
        self.edge_children.len()
    }

    /// Word *i*'s letters.
    #[inline]
    fn word(&self, i: u32) -> &[u8] {
        let lo = self.offsets[i as usize] as usize;
        let hi = self.offsets[i as usize + 1] as usize;
        &self.letters[lo..hi]
    }

    pub fn root(&self) -> Cursor {
        Cursor::Start
    }

    /// Narrows by one character, or `None` if no word continues with it —
    /// the prune signal. Also reports whether what has now been spelled is
    /// itself a word, because in the indexed regimes that answer comes from
    /// the same `PackedChild` the scan already had to load.
    #[inline]
    pub fn advance(&self, cursor: Cursor, letter: u8) -> Option<Step> {
        let expansion = *self.expansion.get(letter as usize)?;
        let mut cursor = cursor;
        let mut is_word = false;
        // One narrowing step per *character*, so a digraph tile consumes
        // two depths and `is_word` is only whatever the last one reports.
        for index in 0..expansion.len as usize {
            let step = self.advance_char(cursor, expansion.chars[index])?;
            cursor = step.cursor;
            is_word = step.is_word;
        }
        Some(Step { cursor, is_word })
    }

    #[inline]
    fn advance_char(&self, cursor: Cursor, letter: u8) -> Option<Step> {
        match cursor {
            // Nothing to check: every letter starts some word, and a
            // one-character word cannot be legal, so there is no question
            // to answer and nothing to look up.
            Cursor::Start => Some(Step {
                cursor: Cursor::First(letter),
                is_word: false,
            }),

            // The first real lookup, by arithmetic rather than search.
            Cursor::First(first) => {
                let slot = first as usize * self.alphabet_len + letter as usize;
                self.step_from(*self.dense.get(slot)?, 2)
            }

            // Scan the node's letter run — contiguous bytes — then one
            // indexed read of the child at the position that matched.
            Cursor::Node {
                start,
                fanout,
                depth,
            } => {
                let lo = start as usize;
                let run = &self.edge_letters[lo..lo + fanout as usize];
                let pos = run.iter().position(|candidate| *candidate == letter)?;
                self.step_from(self.edge_children[lo + pos], depth + 1)
            }

            // No index here: the words themselves are the structure.
            Cursor::Range { from, len, depth } => self.narrow_range(from, len, depth, letter),
        }
    }

    /// Turns a freshly-read child into the next cursor.
    #[inline]
    fn step_from(&self, packed: PackedChild, depth: u8) -> Option<Step> {
        match packed.unpack() {
            Child::Empty => None,
            Child::Index {
                start,
                fanout,
                is_word,
            } => Some(Step {
                cursor: Cursor::Node {
                    start,
                    fanout,
                    depth,
                },
                is_word,
            }),
            Child::Leaf { from, len, is_word } => Some(Step {
                cursor: Cursor::Range { from, len, depth },
                is_word,
            }),
        }
    }

    /// Narrows a word range by one character, bisecting or scanning by
    /// size. Both paths compare only the character at `depth`, never the
    /// accumulated prefix, since every word in the range already shares it.
    #[inline]
    fn narrow_range(&self, from: u32, len: u8, depth: u8, letter: u8) -> Option<Step> {
        let (lo, hi) = (from as usize, from as usize + len as usize);
        let d = depth as usize;

        let (first, last) = if len as usize <= MAX_SCAN_WORDS {
            // Sequential and prefetchable: the words are adjacent.
            let mut first = None;
            let mut last = lo;
            for i in lo..hi {
                match self.word(i as u32).get(d) {
                    Some(c) if *c == letter => {
                        first.get_or_insert(i);
                        last = i;
                    }
                    // Sorted, so once past the letter there is no more.
                    Some(c) if *c > letter => break,
                    _ => {}
                }
            }
            (first?, last + 1)
        } else {
            let start = self.partition_point(lo, hi, d, |c| c < Some(letter));
            let end = self.partition_point(start, hi, d, |c| c == Some(letter));
            if start == end {
                return None;
            }
            (start, end)
        };

        let next_depth = d + 1;
        // A strict prefix sorts immediately before its extensions, so the
        // only candidate for "this is itself a word" is the first entry.
        let is_word = self.word(first as u32).len() == next_depth;
        Some(Step {
            cursor: Cursor::Range {
                from: first as u32,
                len: (last - first) as u8,
                depth: next_depth as u8,
            },
            is_word,
        })
    }

    #[inline]
    fn partition_point(
        &self,
        mut lo: usize,
        hi: usize,
        depth: usize,
        pred: impl Fn(Option<u8>) -> bool,
    ) -> usize {
        let mut hi = hi;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if pred(self.word(mid as u32).get(depth).copied()) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// Whole-word membership by walking the structure.
    ///
    /// Length 1 is `false` unconditionally: no word list we ship has a
    /// single-character entry, and a lone tile is not a legal play, so
    /// answering `true` here would make single-tile openings legal. The
    /// walk cannot produce that answer on its own, since it never resolves
    /// a one-character prefix.
    pub fn contains(&self, word: &[u8]) -> bool {
        // Counted in characters, not tiles: a lone digraph tile is two
        // characters and so is not caught by this rule.
        let characters: usize = word
            .iter()
            .filter_map(|letter| self.expansion.get(*letter as usize))
            .map(|expansion| expansion.len as usize)
            .sum();
        if characters < 2 {
            return false;
        }
        let mut cursor = self.root();
        let mut is_word = false;
        for letter in word {
            match self.advance(cursor, *letter) {
                Some(step) => {
                    cursor = step.cursor;
                    is_word = step.is_word;
                }
                None => return false,
            }
        }
        is_word
    }
}

#[cfg(test)]
mod tests {
    use super::{Child, Cursor, PackedChild};

    #[test]
    fn empty_is_all_zero_so_a_zeroed_table_is_already_empty() {
        assert_eq!(PackedChild::EMPTY, PackedChild::default());
        assert_eq!(PackedChild::EMPTY.0, 0);
        assert!(PackedChild::EMPTY.is_empty());
        assert_eq!(PackedChild::EMPTY.unpack(), Child::Empty);
        assert!(!Child::Empty.is_word());
    }

    /// The whole point of packing: a slot that was never written must not
    /// decode as a usable pointer at entry 0.
    #[test]
    fn a_zeroed_slot_does_not_decode_as_a_valid_pointer() {
        assert!(!matches!(
            PackedChild(0).unpack(),
            Child::Index { .. } | Child::Leaf { .. }
        ));
    }

    /// `Empty` has no tag of its own — it is *implied* by a zero length,
    /// which is the invariant that buys the extra bit. So no packable
    /// child may ever be zero, at any corner of either field. If a bias
    /// ever crept back into the length encoding this is what would catch
    /// it: an `Index` at start 0 with fan-out 1 would pack to zero.
    #[test]
    fn no_real_child_packs_to_zero() {
        for start in [0u32, 1, (PackedChild::MAX_EDGES - 1) as u32] {
            for fanout in [1u8, PackedChild::MAX_FANOUT as u8] {
                for is_word in [false, true] {
                    let packed = Child::Index {
                        start,
                        fanout,
                        is_word,
                    }
                    .pack();
                    assert_ne!(packed, PackedChild::EMPTY);
                }
            }
        }
        for from in [0u32, 1, (PackedChild::MAX_WORDS - 1) as u32] {
            for len in [1u8, PackedChild::MAX_LEAF_LEN as u8] {
                for is_word in [false, true] {
                    let packed = Child::Leaf { from, len, is_word }.pack();
                    assert_ne!(packed, PackedChild::EMPTY);
                }
            }
        }
    }

    #[test]
    fn index_round_trips_including_the_field_extremes() {
        for start in [0u32, 1, 151_804, (PackedChild::MAX_EDGES - 1) as u32] {
            for fanout in [1u8, 28, PackedChild::MAX_FANOUT as u8] {
                for is_word in [false, true] {
                    let child = Child::Index {
                        start,
                        fanout,
                        is_word,
                    };
                    let packed = child.pack();
                    assert_eq!(packed.unpack(), child);
                    assert_eq!(packed.is_word(), is_word);
                    assert!(!packed.is_empty());
                }
            }
        }
    }

    #[test]
    fn leaf_round_trips_including_the_field_extremes() {
        for from in [0u32, 1, 635_090, (PackedChild::MAX_WORDS - 1) as u32] {
            for len in [1u8, 64, PackedChild::MAX_LEAF_LEN as u8] {
                for is_word in [false, true] {
                    let child = Child::Leaf { from, len, is_word };
                    let packed = child.pack();
                    assert_eq!(packed.unpack(), child);
                    assert_eq!(packed.is_word(), is_word);
                    assert!(!packed.is_empty());
                }
            }
        }
    }

    /// `is_word` shares its word with the pointer, so a packing mistake
    /// would show up as the flag bleeding into the payload or vice versa.
    #[test]
    fn is_word_is_independent_of_the_payload() {
        for is_word in [false, true] {
            let index = Child::Index {
                start: 151_804,
                fanout: 28,
                is_word,
            };
            let leaf = Child::Leaf {
                from: 635_090,
                len: 64,
                is_word,
            };
            assert_eq!(index.pack().unpack(), index);
            assert_eq!(leaf.pack().unpack(), leaf);
            assert_eq!(index.pack().is_word(), is_word);
            assert_eq!(leaf.pack().is_word(), is_word);
        }
    }

    #[test]
    #[should_panic(expected = "overflows PackedChild")]
    fn a_word_index_past_the_field_panics_rather_than_truncating() {
        Child::Leaf {
            from: PackedChild::MAX_WORDS as u32,
            len: 1,
            is_word: false,
        }
        .pack();
    }

    #[test]
    #[should_panic(expected = "overflows PackedChild")]
    fn an_edge_index_past_the_field_panics_rather_than_truncating() {
        Child::Index {
            start: PackedChild::MAX_EDGES as u32,
            fanout: 1,
            is_word: false,
        }
        .pack();
    }

    /// `PackedChild` is the storage type, so its size is the whole point:
    /// the sparse index is one byte of letter plus one of these per edge.
    /// `Child` is 8 bytes, so storing the decoded form instead would take
    /// SOWPODS' index from 104 KB to 188 KB and lose the packing argument
    /// entirely. `repr(transparent)` pins the representation.
    #[test]
    fn packed_child_is_exactly_one_word_of_storage() {
        assert_eq!(std::mem::size_of::<PackedChild>(), 4);
        assert_eq!(std::mem::align_of::<PackedChild>(), 4);
        assert!(std::mem::size_of::<Child>() > std::mem::size_of::<PackedChild>());
    }

    /// Small and `Copy`, because move generation passes it by value at
    /// every step of every candidate.
    #[test]
    fn cursor_stays_small() {
        assert!(std::mem::size_of::<Cursor>() <= 8);
    }

    // -----------------------------------------------------------------
    // The dictionary, checked against the implementation in use
    // -----------------------------------------------------------------

    use crate::dictionary::{PrefixCursor, WordListDictionary};
    use crate::model::{Alphabet, Letter, VariantRules};
    use crate::tiered::TieredDictionary;

    fn encode(text: &str, alphabet: &Alphabet) -> Vec<Vec<u8>> {
        let mut buffer = [0u8; 4];
        text.split_whitespace()
            .filter_map(|word| {
                word.chars()
                    .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).map(|l| l.0))
                    .collect::<Option<Vec<u8>>>()
            })
            .collect()
    }

    fn tiny(words: &[&str]) -> (TieredDictionary, Alphabet) {
        let alphabet = VariantRules::official().alphabet;
        let encoded = encode(&words.join(" "), &alphabet);
        (TieredDictionary::from_encoded(encoded, &alphabet), alphabet)
    }

    fn walk(dict: &TieredDictionary, alphabet: &Alphabet, word: &str) -> Option<bool> {
        let mut buffer = [0u8; 4];
        let mut cursor = dict.root();
        let mut is_word = false;
        for ch in word.chars() {
            let letter = alphabet.to_letter(ch.encode_utf8(&mut buffer))?;
            let step = dict.advance(cursor, letter.0)?;
            cursor = step.cursor;
            is_word = step.is_word;
        }
        Some(is_word)
    }

    #[test]
    fn a_small_dictionary_answers_words_prefixes_and_dead_ends() {
        let (dict, alphabet) = tiny(&["CAT", "CATS", "CATTLE", "CAR", "DOG"]);

        // Words.
        for word in ["CAT", "CATS", "CATTLE", "CAR", "DOG"] {
            assert_eq!(walk(&dict, &alphabet, word), Some(true), "{word}");
        }
        // Live prefixes that are not words.
        for prefix in ["CA", "CATT", "CATTL", "DO"] {
            assert_eq!(walk(&dict, &alphabet, prefix), Some(false), "{prefix}");
        }
        // Dead ends prune.
        for dead in ["CATX", "CB", "DX", "CATTLEX"] {
            assert_eq!(walk(&dict, &alphabet, dead), None, "{dead}");
        }
    }

    /// One-character prefixes resolve nothing by design, so the first step
    /// must always succeed and never claim to be a word.
    #[test]
    fn the_first_character_never_prunes_and_is_never_a_word() {
        let (dict, alphabet) = tiny(&["CAT", "DOG"]);
        for ch in 'A'..='Z' {
            let letter = alphabet.to_letter(&ch.to_string()).unwrap();
            let step = dict.advance(dict.root(), letter.0).expect("never prunes");
            assert!(!step.is_word, "{ch}");
            assert!(matches!(step.cursor, Cursor::First(_)));
        }
    }

    /// Words below two characters are dropped rather than mis-stored, and
    /// `contains` must answer false for them however it is asked.
    #[test]
    fn one_letter_entries_are_dropped_and_never_match() {
        let (dict, alphabet) = tiny(&["A", "I", "AT", "IT"]);
        assert_eq!(dict.word_count(), 2);
        let a = alphabet.to_letter("A").unwrap().0;
        assert!(!dict.contains(&[a]));
        assert!(dict.contains(&[a, alphabet.to_letter("T").unwrap().0]));
    }

    /// The real check. For every word in a shipped list, walk it character
    /// by character through both implementations and compare the prune
    /// signal and the is_word answer at every depth. Then do the same over
    /// prefixes extended by every letter of the alphabet, which is what
    /// exercises the dead-end path — a structure can get every word right
    /// and still fail to prune correctly.
    fn differential(text: &str, rules: &VariantRules, sample: usize) {
        let alphabet = &rules.alphabet;
        let baseline = WordListDictionary::from_word_list(text.to_string());
        let tiered = TieredDictionary::from_encoded(encode(text, alphabet), alphabet);

        let words: Vec<&str> = text.split_whitespace().collect();
        let step = (words.len() / sample).max(1);

        for word in words.iter().step_by(step) {
            let letters: Vec<Letter> = {
                let mut buffer = [0u8; 4];
                word.chars()
                    .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).unwrap())
                    .collect()
            };
            if letters.len() < 2 {
                continue;
            }

            // Walk the word itself, comparing at every depth.
            let mut base = Some(baseline.prefix_cursor());
            let mut cursor = Some(tiered.root());
            let mut tiered_is_word = false;
            for (depth, letter) in letters.iter().enumerate() {
                base = base.and_then(|c| c.advance(*letter, alphabet));
                cursor = cursor.and_then(|c| {
                    tiered.advance(c, letter.0).map(|s| {
                        tiered_is_word = s.is_word;
                        s.cursor
                    })
                });
                assert_eq!(
                    base.is_some(),
                    cursor.is_some(),
                    "{word}: prune disagreed at depth {}",
                    depth + 1
                );
                if let Some(b) = base.filter(|_| depth + 1 >= 2) {
                    assert_eq!(
                        b.is_word(),
                        tiered_is_word,
                        "{word}: is_word disagreed at depth {}",
                        depth + 1
                    );
                }
            }

            // Then every one-letter extension of every prefix, which is
            // where a structure that stores words correctly can still
            // prune wrongly.
            for cut in 2..=letters.len() {
                let mut base = Some(baseline.prefix_cursor());
                let mut cur = Some(tiered.root());
                for letter in &letters[..cut] {
                    base = base.and_then(|c| c.advance(*letter, alphabet));
                    cur = cur.and_then(|c| tiered.advance(c, letter.0).map(|s| s.cursor));
                }
                let (Some(base), Some(cur)) = (base, cur) else {
                    panic!("{word}: prefix of {cut} should exist in both");
                };
                for index in 0..alphabet.len() as u8 {
                    let extra = Letter(index);
                    let b = base.advance(extra, alphabet);
                    let t = tiered.advance(cur, index);
                    assert_eq!(
                        b.is_some(),
                        t.is_some(),
                        "{word}[..{cut}] + letter {index}: prune disagreed"
                    );
                    if let (Some(b), Some(t)) = (b, t) {
                        assert_eq!(
                            b.is_word(),
                            t.is_word,
                            "{word}[..{cut}] + letter {index}: is_word disagreed"
                        );
                    }
                }
            }

            // And whole-word membership.
            let bytes: Vec<u8> = letters.iter().map(|l| l.0).collect();
            assert!(tiered.contains(&bytes), "{word}: contains said false");
        }
    }

    /// `allowed_letters` is a hand-written override of a trait default, so
    /// the two must agree. Checks real cross-word contexts drawn from the
    /// word list, including the cases most likely to diverge: an empty
    /// prefix (nothing to hoist), an empty suffix, and a prefix that is
    /// itself a dead end.
    fn allowed_letters_agrees_with_the_default(text: &str, rules: &VariantRules) {
        use crate::dictionary::Dictionary;
        let alphabet = &rules.alphabet;
        let tiered = TieredDictionary::from_encoded(encode(text, alphabet), alphabet);
        let baseline = WordListDictionary::from_word_list(text.to_string());

        let words: Vec<&str> = text.split_whitespace().collect();
        let stride = (words.len() / 400).max(1);
        let mut contexts: Vec<(Vec<Letter>, Vec<Letter>)> = Vec::new();
        for word in words.iter().step_by(stride) {
            let mut buffer = [0u8; 4];
            let letters: Vec<Letter> = word
                .chars()
                .filter_map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)))
                .collect();
            if letters.len() < 2 {
                continue;
            }
            // Every split of the word: prefix empty at 0, suffix empty at
            // the end, and everything between.
            for cut in 0..letters.len() {
                contexts.push((letters[..cut].to_vec(), letters[cut + 1..].to_vec()));
            }
        }
        // A prefix no word starts with, so the fast path must bail rather
        // than assume the walk succeeded.
        contexts.push((vec![Letter(25), Letter(25), Letter(25)], vec![]));

        for (before, after) in &contexts {
            assert_eq!(
                tiered.allowed_letters(before, after, alphabet),
                baseline.allowed_letters(before, after, alphabet),
                "disagreed for prefix {before:?} suffix {after:?}"
            );
        }
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn allowed_letters_matches_the_default_on_sowpods() {
        allowed_letters_agrees_with_the_default(
            crate::dictionary::sowpods_word_list(),
            &VariantRules::official(),
        );
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn allowed_letters_matches_the_default_on_spanish() {
        allowed_letters_agrees_with_the_default(
            crate::dictionary::spanish_word_list(),
            &VariantRules::spanish(),
        );
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn allowed_letters_matches_the_default_on_german() {
        allowed_letters_agrees_with_the_default(
            crate::dictionary::german_word_list(),
            &VariantRules::german(),
        );
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn matches_the_current_implementation_on_sowpods() {
        differential(
            crate::dictionary::sowpods_word_list(),
            &VariantRules::official(),
            4000,
        );
    }

    /// Spanish is the one that catches ordering mistakes: Ñ is filed
    /// between N and O by letter index, where its code point sorts after Z,
    /// and CH/LL/RR are single tiles spanning two characters.
    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn matches_the_current_implementation_on_spanish() {
        differential(
            crate::dictionary::spanish_word_list(),
            &VariantRules::spanish(),
            4000,
        );
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn matches_the_current_implementation_on_german() {
        differential(
            crate::dictionary::german_word_list(),
            &VariantRules::german(),
            4000,
        );
    }

    #[test]
    #[cfg(not(target_arch = "wasm32"))]
    fn matches_the_current_implementation_on_enable2k() {
        differential(
            crate::dictionary::enable2k_word_list(),
            &VariantRules::north_american(),
            4000,
        );
    }
}
