//! Dev-only: how wide do the sparse index's fields have to be?
//!
//! Usage: `cargo run --release -p rules-shared --example sparse_budget`
//!
//! Counts the structures the proposed layout would actually allocate, for
//! every shipped word list, so the field widths are chosen against measured
//! counts rather than against SOWPODS and a hope about the rest. Reports:
//!
//! - **edges** — entries in the parallel `letters` / `child` / `is_word`
//!   arrays. This is what a `u16` child pointer would have to address.
//! - **nodes** / **leaves** — the split of those edges by child kind, which
//!   the earlier sweep never separated and which the cost table is still
//!   carrying as an upper bound.
//!
//! A group is given a child index only while it holds more than T1 words;
//! below that it becomes a leaf and the arena is searched directly.

use rules_shared::{
    Alphabet, VariantRules, enable2k_word_list, german_word_list, sowpods_word_list,
    spanish_word_list,
};

/// Everything a `u16` field would have to hold, counted per list.
#[derive(Default)]
struct Budget {
    edges: usize,
    nodes: usize,
    leaves: usize,
    max_fanout: usize,
}

/// Walks the sorted word list as a trie without building one: a group is a
/// contiguous run of words sharing a prefix, so its children are found by
/// scanning the run for changes at `depth`.
fn measure(words: &[Vec<u8>], t1: usize) -> Budget {
    let mut budget = Budget::default();
    // (start, end, depth) of each group still to be indexed. The two-letter
    // dense table is the root set, so start at depth 2.
    let mut stack: Vec<(usize, usize, usize)> = Vec::new();

    // Seed with the dense table's occupied slots.
    let mut i = 0;
    while i < words.len() {
        let key = prefix(&words[i], 2);
        let mut j = i;
        while j < words.len() && prefix(&words[j], 2) == key {
            j += 1;
        }
        if j - i > t1 {
            stack.push((i, j, 2));
        }
        i = j;
    }

    while let Some((start, end, depth)) = stack.pop() {
        let mut fanout = 0;
        let mut i = start;
        while i < end {
            // Words that end exactly here carry no child edge; they are
            // recorded by the parent's is_word bit, already counted.
            if words[i].len() <= depth {
                i += 1;
                continue;
            }
            let letter = words[i][depth];
            let mut j = i;
            while j < end && words[j].len() > depth && words[j][depth] == letter {
                j += 1;
            }

            budget.edges += 1;
            fanout += 1;
            if j - i > t1 {
                budget.nodes += 1;
                stack.push((i, j, depth + 1));
            } else {
                budget.leaves += 1;
            }
            i = j;
        }
        budget.max_fanout = budget.max_fanout.max(fanout);
    }

    budget
}

fn prefix(word: &[u8], depth: usize) -> Vec<u8> {
    word[..depth.min(word.len())].to_vec()
}

fn encode(text: &str, alphabet: &Alphabet) -> Vec<Vec<u8>> {
    let mut buffer = [0u8; 4];
    let mut encoded: Vec<Vec<u8>> = text
        .split_whitespace()
        .filter_map(|word| {
            word.chars()
                .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).map(|l| l.0))
                .collect::<Option<Vec<u8>>>()
        })
        .collect();
    encoded.sort_unstable();
    encoded.dedup();
    encoded
}

fn main() {
    println!(
        "{:<10} {:>4} {:>9} {:>9} {:>9} {:>8}  u16 child?",
        "list", "T1", "edges", "nodes", "leaves", "fanout"
    );

    for (name, text, rules) in [
        ("sowpods", sowpods_word_list(), VariantRules::official()),
        (
            "enable2k",
            enable2k_word_list(),
            VariantRules::north_american(),
        ),
        ("german", german_word_list(), VariantRules::german()),
        ("spanish", spanish_word_list(), VariantRules::spanish()),
    ] {
        let words = encode(text, &rules.alphabet);
        println!("{name} — {} words", words.len());
        for t1 in [32usize, 64, 128] {
            let budget = measure(&words, t1);
            // A u16 child pointer needs every edge index representable.
            // With the 2-bit tag that is 14 bits; without a tag, 16.
            let verdict = if budget.edges < (1 << 14) {
                "yes, even with the 2-bit tag"
            } else if budget.edges < (1 << 16) {
                "only untagged"
            } else {
                "NO"
            };
            println!(
                "           {t1:>4} {:>9} {:>9} {:>9} {:>8}  {verdict}",
                budget.edges, budget.nodes, budget.leaves, budget.max_fanout
            );
        }
    }
}
