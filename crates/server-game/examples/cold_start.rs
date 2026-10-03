//! Dev-only: what does the *first* request touching a dictionary cost?
//!
//! `GameSession::new` resolves `dictionary_by_name`, which derefs a
//! `LazyLock` — so the first game created for an edition after a server
//! start builds the whole structure inside that request. The bot-move
//! timing recorded as `elapsed_us` wraps only `engine.choose_action`, a
//! later request, so this cost is invisible to it. That is the gap the
//! "bots feel slow on the first move of a new game" report points at.

use std::time::Instant;

fn main() {
    let language = std::env::args().nth(1).unwrap_or_else(|| "sowpods".into());

    let cold = Instant::now();
    let dictionary = rules_shared::dictionary_by_name(&language).expect("known dictionary");
    let cold_ms = cold.elapsed().as_secs_f64() * 1000.0;

    let warm = Instant::now();
    let again = rules_shared::dictionary_by_name(&language).expect("known dictionary");
    let warm_us = warm.elapsed().as_secs_f64() * 1e6;

    println!("{language}: cold {cold_ms:.1} ms   warm {warm_us:.2} us");
    println!(
        "  resident {:.2} MB",
        dictionary.resident_bytes() as f64 / (1024.0 * 1024.0)
    );
    std::hint::black_box((dictionary.word_count(), again.word_count()));
}
