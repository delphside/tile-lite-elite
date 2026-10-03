//! Dev-only benchmark: what dictionary construction and lookup actually
//! cost, per word list. Never built into the shipped binary — examples
//! aren't part of a release build — this is a `cargo run --example` tool.
//!
//! Usage: `cargo run --release -p rules-shared --example dictionary_bench`
//! (release matters: a debug build's allocation and comparison costs are
//! nowhere near what a deployed server sees, and construction is dominated
//! by exactly those.)
//!
//! Three things are measured separately, because they have different
//! consumers and different fixes:
//!
//! - **construction** — paid once per process on the server, but once per
//!   *page load* in the wasm client, which is the case that hurts.
//! - **`is_word`** — the only dictionary operation the client performs.
//! - **prefix cursor walks** — what move generation actually leans on, and
//!   the reason `sorted_words` exists at all.
//!
//! Lookup workloads are drawn from the word list itself rather than
//! synthesised, so hit/miss ratios and prefix depths resemble real traffic
//! instead of favouring whichever implementation likes short keys.

use std::fs::OpenOptions;
use std::io::Write;
use std::process::Command;
use std::time::Instant;

use rules_shared::dictionary::PrefixCursor;
use rules_shared::{
    Dictionary, VariantRules, WordListDictionary, enable2k_word_list, german_word_list,
    sowpods_word_list, spanish_word_list,
};

/// `variant` names the implementation being measured, so rows from before
/// and after a construction/lookup change stay distinguishable in one file
/// rather than only being separable by reading the git log.
const RESULTS_CSV_HEADER: &str = "timestamp_unix_seconds,git_commit,host,variant,list,words,construct_ms,is_word_hit_ns,is_word_miss_ns,prefix_advance_ns\n";

/// The implementation these numbers describe. Bump this when the storage
/// or lookup strategy changes, so the CSV keeps old rows comparable.
const VARIANT: &str = "hashset+vec-of-vec-char";

/// This workload is memory-bound, so the machine matters as much as the
/// code — the same binary shows a 6x spread on prefix walks between a
/// modern laptop and the deployment VM. Rows are useless without it.
fn host_label() -> String {
    std::env::var("BENCH_HOST").unwrap_or_else(|_| {
        std::process::Command::new("hostname")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".to_string())
    })
}

/// Same convention as `engine_timing_bench`: record the commit, and mark a
/// dirty tree rather than refusing to run — benchmarking mid-change is the
/// normal case here.
fn git_commit_label() -> String {
    let hash = Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    let dirty = Command::new("git")
        .args(["status", "--porcelain"])
        .output()
        .ok()
        .is_some_and(|output| output.status.success() && !output.stdout.is_empty());
    if dirty { format!("{hash}-dirty") } else { hash }
}

fn append_result_rows(rows: &str) -> std::io::Result<std::path::PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("examples/dictionary_bench_results.csv");
    let is_new_file = !path.exists();
    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    if is_new_file {
        file.write_all(RESULTS_CSV_HEADER.as_bytes())?;
    }
    file.write_all(rows.as_bytes())?;
    Ok(path)
}

/// Enough repetitions that a single unlucky scheduler slice can't dominate,
/// while keeping a full run to a few seconds.
const CONSTRUCTION_RUNS: usize = 5;
const LOOKUP_SAMPLE: usize = 20_000;

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs in timing data"));
    values[values.len() / 2]
}

/// A spread of words across the whole list rather than the first N, which
/// would sample only one corner of the alphabet.
fn spread<'a>(words: &[&'a str], count: usize) -> Vec<&'a str> {
    if words.len() <= count {
        return words.to_vec();
    }
    let stride = words.len() / count;
    (0..count).map(|i| words[i * stride]).collect()
}

fn main() {
    let timestamp_unix_seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time before epoch")
        .as_secs();
    let commit = git_commit_label();
    let host = host_label();
    let mut rows = String::new();

    println!("variant: {VARIANT}  host: {host}");
    println!();
    println!(
        "{:<10} {:>8} {:>12} {:>12} {:>12} {:>12}",
        "list", "words", "construct", "is_word hit", "is_word miss", "prefix walk"
    );
    println!("{}", "-".repeat(70));

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
        let all: Vec<&str> = text.split_whitespace().collect();

        let construct_ms = median(
            (0..CONSTRUCTION_RUNS)
                .map(|_| {
                    let owned = text.to_string();
                    let start = Instant::now();
                    let dictionary = WordListDictionary::from_word_list(owned);
                    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
                    // Defeat any chance of the construction being optimised
                    // away as unused.
                    std::hint::black_box(dictionary.is_word("ACE"));
                    elapsed
                })
                .collect(),
        );

        let dictionary = WordListDictionary::from_word_list(text.to_string());
        let sample = spread(&all, LOOKUP_SAMPLE);

        // Hits: real words, so the lookup runs to completion rather than
        // bailing early on a first-character mismatch.
        let start = Instant::now();
        let mut found = 0usize;
        for word in &sample {
            if dictionary.is_word(word) {
                found += 1;
            }
        }
        let hit_ns = start.elapsed().as_secs_f64() * 1e9 / sample.len() as f64;
        assert_eq!(found, sample.len(), "{name}: every sampled word should hit");

        // Misses: a real word with one character appended is a far harder
        // miss than a random string — it shares its whole prefix, so the
        // lookup can't discriminate early.
        let misses: Vec<String> = sample.iter().map(|word| format!("{word}Q")).collect();
        let start = Instant::now();
        let mut absent = 0usize;
        for word in &misses {
            if !dictionary.is_word(word) {
                absent += 1;
            }
        }
        let miss_ns = start.elapsed().as_secs_f64() * 1e9 / misses.len() as f64;
        assert_eq!(absent, misses.len(), "{name}: none of these should hit");

        // Prefix walks: advance a cursor letter by letter through a real
        // word, which is what move generation does as it extends a play.
        // Words are capped at 8 letters so the walk cost reflects typical
        // play rather than the rare 15-letter outlier.
        let walk_words: Vec<&&str> = sample.iter().filter(|w| w.chars().count() <= 8).collect();
        let alphabet = &rules.alphabet;
        let start = Instant::now();
        let mut steps = 0usize;
        for word in &walk_words {
            let mut cursor = Some(dictionary.root_cursor());
            for grapheme in word.chars() {
                let Some(current) = cursor else { break };
                let Some(letter) = alphabet.to_letter(&grapheme.to_string()) else {
                    cursor = None;
                    break;
                };
                cursor = current.advance(letter, alphabet);
                steps += 1;
            }
            std::hint::black_box(&cursor);
        }
        let walk_ns = start.elapsed().as_secs_f64() * 1e9 / steps.max(1) as f64;

        println!(
            "{name:<10} {:>8} {construct_ms:>9.1} ms {hit_ns:>9.0} ns {miss_ns:>9.0} ns {walk_ns:>9.0} ns",
            all.len(),
        );
        rows.push_str(&format!(
            "{timestamp_unix_seconds},{commit},{host},{VARIANT},{name},{},{construct_ms:.1},{hit_ns:.0},{miss_ns:.0},{walk_ns:.0}\n",
            all.len(),
        ));
    }

    println!();
    println!("construct = median of {CONSTRUCTION_RUNS} full builds from text");
    println!("is_word   = per-call, {LOOKUP_SAMPLE} words spread across the list");
    println!("prefix    = per cursor advance (one letter), words of <= 8 letters");
    println!();
    println!("Letter counts vary per list, so compare a column across rows only");
    println!("with that in mind — german/spanish are 2-4x the word count.");

    match append_result_rows(&rows) {
        Ok(path) => println!("\nrecorded to {}", path.display()),
        Err(error) => eprintln!("\nfailed to record results: {error}"),
    }
}
