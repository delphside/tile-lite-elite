//! Proposes `greylist.txt` — the words no engine will choose.
//!
//! ```text
//! cargo run --release -p rules-shared --example generate-greylist > crates/rules-shared/src/wordlists/greylist.txt
//! ```
//!
//! Two sources, unioned:
//!
//! 1. **rustrict**, `is(Type::ANY)` — anything it flags at all, at any severity.
//! 2. **`greylist-stems.txt`**, the curated stems and their exclusions.
//!
//! The stems exist because rustrict's recall gaps are arbitrary: it flags
//! NEGROES, NEGROID and NEGROIDS but not NEGRO, POOFTER but not POOF, SMUTTY
//! but not SMUT, and misses MONG entirely. A base word slipping through while
//! its inflections are caught is exactly what the greylist exists to prevent.
//!
//! Erring long is deliberate and close to free — a wrongly greyed word is one
//! the bot declines to play, which nobody can observe, and the cost of the list
//! no longer scales with its length (see `GreedyEngine::best_move`).
//!
//! English only: sowpods and enable2k. German and Spanish are out of scope
//! because neither can be reviewed by somebody who does not speak the language.
//!
//! Also **checks the stem file** and reports on stderr: exact entries that are
//! in no dictionary (typos), and exclusions that never fired (dead weight).

use std::collections::BTreeSet;

use rustrict::{CensorStr, Type};

const STEMS: &str = include_str!("../src/wordlists/greylist-stems.txt");

/// The version this list was generated with, recorded in the output header.
/// Pinned in `Cargo.toml` — a regenerated list that silently differs is worse
/// than no list.
const RUSTRICT_VERSION: &str = "0.7.38";

#[derive(Default)]
struct Stems {
    prefixes: Vec<String>,
    exact: BTreeSet<String>,
    exclusions: BTreeSet<String>,
}

/// `WORD` exact · `PREFIX*` expand · `!WORD` never grey.
fn parse_stems(text: &str) -> Stems {
    let mut stems = Stems::default();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if let Some(word) = line.strip_prefix('!') {
            stems.exclusions.insert(word.to_string());
        } else if let Some(prefix) = line.strip_suffix('*') {
            stems.prefixes.push(prefix.to_string());
        } else {
            stems.exact.insert(line.to_string());
        }
    }
    stems
}

/// Matches the measurement this list was sized against: lowercase first,
/// because an all-caps string raises `SPAM` on its own and has nothing to do
/// with the word.
fn is_flagged(word: &str) -> bool {
    word.to_lowercase().is(Type::ANY)
}

fn main() {
    let dictionaries = [
        rules_shared::sowpods_word_list(),
        rules_shared::enable2k_word_list(),
    ];
    let words: BTreeSet<&str> = dictionaries.iter().flat_map(|text| text.lines()).collect();

    let stems = parse_stems(STEMS);

    let flagged: BTreeSet<&str> = words.iter().copied().filter(|w| is_flagged(w)).collect();

    let mut from_stems: BTreeSet<&str> = BTreeSet::new();
    for word in &words {
        let by_prefix = stems.prefixes.iter().any(|p| word.starts_with(p.as_str()));
        if by_prefix || stems.exact.contains(*word) {
            from_stems.insert(word);
        }
    }

    let mut greylist: BTreeSet<&str> = flagged.union(&from_stems).copied().collect();
    greylist.retain(|w| !stems.exclusions.contains(*w));
    // A denied word is gone from the dictionaries anyway; listing it here as
    // well would be noise in a file meant to be read.
    greylist.retain(|w| !rules_shared::wordlists::is_denied(w));

    // Checks on the stem file itself, so a typo or a stale exclusion is
    // reported rather than silently doing nothing.
    let unknown: Vec<&String> = stems
        .exact
        .iter()
        .filter(|w| !words.contains(w.as_str()))
        .collect();
    let idle: Vec<&String> = stems
        .exclusions
        .iter()
        .filter(|w| !stems.prefixes.iter().any(|p| w.starts_with(p.as_str())))
        .collect();

    eprintln!("dictionary words   : {}", words.len());
    eprintln!("rustrict flagged   : {}", flagged.len());
    eprintln!(
        "added by the stems : {}",
        from_stems.difference(&flagged).count()
    );
    eprintln!(
        "GREYLIST           : {} ({:.2}% of the dictionary)",
        greylist.len(),
        greylist.len() as f64 * 100.0 / words.len() as f64
    );
    if !unknown.is_empty() {
        eprintln!("\nexact stems in no dictionary (typos?): {unknown:?}");
    }
    if !idle.is_empty() {
        eprintln!("\nexclusions that never fire (dead weight): {idle:?}");
    }

    println!("# Words a person may still play, and an engine will not choose.");
    println!("#");
    println!("# GENERATED — do not edit by hand. Regenerate with:");
    println!("#   cargo run --release -p rules-shared --example generate-greylist \\");
    println!("#     > crates/rules-shared/src/wordlists/greylist.txt");
    println!("#");
    println!("# Sources: rustrict {RUSTRICT_VERSION} `is(Type::ANY)`, plus the curated stems");
    println!("# in greylist-stems.txt. Edit the stems, not this file.");
    println!("#");
    println!(
        "# {} words, {:.2}% of the {} in sowpods and enable2k combined.",
        greylist.len(),
        greylist.len() as f64 * 100.0 / words.len() as f64,
        words.len()
    );
    println!("#");
    println!("# See docs/3.5-word-lists-and-dictionaries.md.");
    for word in &greylist {
        println!("{word}");
    }
}
