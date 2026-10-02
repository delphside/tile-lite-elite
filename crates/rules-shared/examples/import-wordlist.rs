//! Puts an upstream word list into the form the committed files hold.
//!
//! ```text
//! cargo run --release -p rules-shared --example import-wordlist -- sowpods < words.txt > crates/rules-shared/src/sowpods.txt
//! ```
//!
//! Reads plain text on stdin — one word per line, any case — and writes the
//! normalised list to stdout. Extracting that plain text from whatever upstream
//! ships is a shell one-liner per source (`gunzip`, `jq -r '.[]'`) and stays
//! outside this tool deliberately: teaching it to un-gzip and parse JSON would
//! add both dependencies to a crate that compiles to wasm, to save one line run
//! once a year. See `docs/3.5-word-lists-and-dictionaries.md`.
//!
//! `--remove-denied` additionally drops the denylisted words. It is a separate
//! flag, and meant to be a separate commit, because the first deviation of a
//! list from its upstream source should be visible in the history rather than
//! being something the file has silently had done to it since before it was
//! first committed.
//!
//! Never built into the shipped binary — examples are not part of the release.

use std::io::Read;

use rules_shared::VariantRules;

fn rules_for(edition: &str) -> Option<VariantRules> {
    Some(match edition {
        "sowpods" => VariantRules::official(),
        "enable2k" => VariantRules::north_american(),
        "german" => VariantRules::german(),
        "spanish" => VariantRules::spanish(),
        _ => return None,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let remove_denied = args.iter().any(|a| a == "--remove-denied");
    let edition = args.iter().find(|a| !a.starts_with("--"));

    let Some(edition) = edition else {
        eprintln!(
            "usage: import-wordlist <sowpods|enable2k|german|spanish> [--remove-denied] < words.txt"
        );
        std::process::exit(2);
    };
    let Some(rules) = rules_for(edition) else {
        eprintln!("unknown edition {edition:?} — expected sowpods, enable2k, german or spanish");
        std::process::exit(2);
    };

    let mut input = String::new();
    if let Err(error) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("could not read stdin: {error}");
        std::process::exit(1);
    }
    let read_in = input.lines().filter(|l| !l.trim().is_empty()).count();

    let normalised = rules_shared::wordlists::normalise(&input, &rules.alphabet);
    let after_form = normalised.lines().count();

    let output = if remove_denied {
        rules_shared::wordlists::remove_denied(&normalised)
    } else {
        normalised
    };
    let written = output.lines().count();

    // Counts on stderr so stdout stays a clean word list that can be redirected
    // straight into the committed file — and so the drop is visible, since
    // silently importing a tenth of a list is a mistake worth noticing.
    eprintln!("{edition}: {read_in} read, {after_form} after normalising, {written} written");
    if remove_denied {
        eprintln!("  denylist removed {} words", after_form - written);
    } else {
        eprintln!("  denylist NOT applied — pass --remove-denied, as a separate commit");
    }

    print!("{output}");
}
