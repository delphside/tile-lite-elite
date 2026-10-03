//! Dev-only: trace one word through every structure of the proposed
//! tiered layout, printing the real index at each hop.
//!
//! Two uses. It produced the numbers in the design doc's end-to-end
//! figure, so those are measurements rather than sketches. And once
//! construction lands it is the independent oracle to check it against —
//! it derives the same answers straight from the sorted word list, by a
//! different route than the real structures will.
//!
//! Usage: `cargo run --release -p rules-shared --example trace_word -- CATTLE`
//!
//! Simulates the layout from the sorted word list, since construction
//! doesn't exist yet. Edge positions are assigned breadth-first from the
//! dense table, which is the order construction will use.

use rules_shared::{Alphabet, VariantRules, sowpods_word_list};
use std::collections::HashMap;

use rules_shared::tiered::MAX_LEAF_WORDS;

fn grapheme_of(alphabet: &Alphabet, letter: u8) -> String {
    alphabet
        .to_grapheme(rules_shared::Letter(letter))
        .map(|g| g.chars().collect::<String>())
        .unwrap_or_else(|| "?".into())
}

fn encode(text: &str, alphabet: &Alphabet) -> Vec<Vec<u8>> {
    let mut buffer = [0u8; 4];
    let mut words: Vec<Vec<u8>> = text
        .split_whitespace()
        .filter_map(|word| {
            word.chars()
                .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).map(|l| l.0))
                .collect::<Option<Vec<u8>>>()
        })
        .collect();
    words.sort_unstable();
    words.dedup();
    words
}

/// The children of a group: (letter, sub-range) per distinct next letter.
fn children(words: &[Vec<u8>], (lo, hi): (usize, usize), depth: usize) -> Vec<(u8, usize, usize)> {
    let mut out = Vec::new();
    let mut i = lo;
    while i < hi {
        if words[i].len() <= depth {
            i += 1;
            continue;
        }
        let letter = words[i][depth];
        let mut j = i;
        while j < hi && words[j].len() > depth && words[j][depth] == letter {
            j += 1;
        }
        out.push((letter, i, j));
        i = j;
    }
    out
}

fn is_word_at(words: &[Vec<u8>], (lo, _hi): (usize, usize), depth: usize) -> bool {
    // A strict prefix sorts immediately before its extensions, so the only
    // candidate is the first entry of the group.
    words[lo].len() == depth
}

fn main() {
    let target = std::env::args().nth(1).unwrap_or_else(|| "CATTLE".into());
    let rules = VariantRules::official();
    let alphabet = &rules.alphabet;
    let words = encode(sowpods_word_list(), alphabet);
    let n = alphabet.len();
    let mut buffer = [0u8; 4];
    let encoded: Vec<u8> = target
        .chars()
        .map(|ch| alphabet.to_letter(ch.encode_utf8(&mut buffer)).unwrap().0)
        .collect();

    // --- dense table over the first two characters -------------------
    let mut dense: HashMap<usize, (usize, usize)> = HashMap::new();
    let mut i = 0;
    while i < words.len() {
        let key = words[i][0] as usize * n + words[i][1] as usize;
        let mut j = i;
        while j < words.len() && words[j][0] == words[i][0] && words[j][1] == words[i][1] {
            j += 1;
        }
        dense.insert(key, (i, j));
        i = j;
    }
    let occupied = dense.len();

    // --- assign edge positions breadth-first, as construction will ---
    // queue entries: (range, depth) for groups that get an index node
    let mut queue: Vec<((usize, usize), usize)> = Vec::new();
    let mut slots: Vec<usize> = dense.keys().copied().collect();
    slots.sort_unstable();
    for slot in &slots {
        let range = dense[slot];
        if range.1 - range.0 > MAX_LEAF_WORDS {
            queue.push((range, 2));
        }
    }
    // node_start: range -> first edge index of that node's run
    let mut node_start: HashMap<(usize, usize), usize> = HashMap::new();
    let mut next_edge = 0usize;
    let mut head = 0usize;
    while head < queue.len() {
        let (range, depth) = queue[head];
        head += 1;
        let kids = children(&words, range, depth);
        node_start.insert(range, next_edge);
        next_edge += kids.len();
        for (_letter, lo, hi) in kids {
            if hi - lo > MAX_LEAF_WORDS {
                queue.push(((lo, hi), depth + 1));
            }
        }
    }

    println!("sowpods: {} words, alphabet {n}", words.len());
    println!(
        "dense: {} of {} slots occupied ({}%)\n",
        occupied,
        n * n,
        occupied * 100 / (n * n)
    );

    // --- walk the target --------------------------------------------
    let slot = encoded[0] as usize * n + encoded[1] as usize;
    let mut range = dense[&slot];
    let prefix2: String = target.chars().take(2).collect();
    println!(
        "dense[{slot}]  ({prefix2})  words {}..{}  size {}  is_word {}  {}",
        range.0,
        range.1,
        range.1 - range.0,
        is_word_at(&words, range, 2),
        if range.1 - range.0 > MAX_LEAF_WORDS {
            "-> Index"
        } else {
            "-> Leaf"
        }
    );

    let mut depth = 2;
    while range.1 - range.0 > MAX_LEAF_WORDS && depth < encoded.len() {
        let kids = children(&words, range, depth);
        let start = node_start[&range];
        let pos = kids.iter().position(|k| k.0 == encoded[depth]).unwrap();
        let (_l, lo, hi) = kids[pos];
        let letters: String = kids
            .iter()
            .map(|k| grapheme_of(alphabet, k.0))
            .collect::<Vec<_>>()
            .join("");
        let child_is_word = is_word_at(&words, (lo, hi), depth + 1);
        println!(
            "  node@edge {start:>6} fanout {:>2} [{letters}]  pick '{}' at +{pos} (edge {})  \
             -> words {lo}..{hi} size {}  is_word {child_is_word}  {}",
            kids.len(),
            target.chars().nth(depth).unwrap(),
            start + pos,
            hi - lo,
            if hi - lo > MAX_LEAF_WORDS {
                "Index"
            } else {
                "Leaf"
            }
        );
        range = (lo, hi);
        depth += 1;
    }

    // --- the arena ---------------------------------------------------
    let word_index = words.iter().position(|w| *w == encoded).unwrap();
    let offset: usize = words[..word_index].iter().map(|w| w.len()).sum();
    println!(
        "\nleaf range words {}..{} (size {}), scanned or bisected to word {word_index}",
        range.0,
        range.1,
        range.1 - range.0
    );
    println!(
        "offsets[{word_index}] = {offset}, offsets[{}] = {}",
        word_index + 1,
        offset + encoded.len()
    );
    println!(
        "letters[{}..{}] = {:?}",
        offset,
        offset + encoded.len(),
        encoded
    );
    println!(
        "total letters in arena: {}",
        words.iter().map(|w| w.len()).sum::<usize>()
    );
    // The full child table of the first sparse node, which is what the
    // design doc's "the node at CA" figure draws. Printed in full so the
    // figure can pick cells that genuinely differ rather than inventing
    // flags: most CA? trigrams are words, which is easy to get wrong.
    let root = dense[&slot];
    if root.1 - root.0 > MAX_LEAF_WORDS {
        let kids = children(&words, root, 2);
        let start = node_start[&root];
        println!(
            "\n--- node at {prefix2}: {} edges from {start} ---",
            kids.len()
        );
        println!("  edge  +pos  letter  is_word  size  kind");
        for (pos, (letter, lo, hi)) in kids.iter().enumerate() {
            let indexed = hi - lo > MAX_LEAF_WORDS;
            println!(
                "  {:>4}  {:>4}  {:>6}  {:>7}  {:>4}  {}",
                start + pos,
                pos,
                grapheme_of(alphabet, *letter),
                is_word_at(&words, (*lo, *hi), 3),
                hi - lo,
                if indexed {
                    format!("Index @{}", node_start[&(*lo, *hi)])
                } else {
                    format!("Leaf from {lo}")
                }
            );
        }
    }

    println!("\n--- first-letter ranges (checking the doc's figures) ---");
    for target_letter in [0u8, 1, 2] {
        let lo = words.iter().position(|w| w[0] == target_letter).unwrap();
        let hi = words.iter().rposition(|w| w[0] == target_letter).unwrap() + 1;
        println!(
            "  {}: words {lo}..{hi}  size {}",
            grapheme_of(alphabet, target_letter),
            hi - lo
        );
    }

    println!("first few words in the leaf range:");
    for w in &words[range.0..range.1.min(range.0 + 6)] {
        let s: String = w.iter().map(|b| grapheme_of(alphabet, *b)).collect();
        println!("  {s}");
    }
}
// appended check: per-first-letter cumulative ranges
