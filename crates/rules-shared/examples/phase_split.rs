//! Dev-only: where does a bot's turn actually spend its time?
//!
//! Usage: `cargo run --release -p rules-shared --example phase_split`
//!
//! The dictionary work in a turn splits into two phases that behave
//! completely differently, and it matters which one dominates before
//! optimising either:
//!
//! - **cross-checks** — `apply_move` re-derives, for every empty square and
//!   both directions, which letters could legally sit there. Each
//!   constrained square asks the dictionary once per letter of the
//!   alphabet. This happens **once per move applied**, and is a full-board
//!   sweep rather than an incremental update.
//! - **generation** — `enumerate_legal_moves` walks the prefix cursor
//!   millions of times per turn, pruning as it goes.
//!
//! A 2x improvement to cross-checks is worth little if they are 2% of the
//! turn, so this reports the ratio rather than either number alone.
//!
//! **Read the `constr` column before trusting the ratio.** The sweep only
//! costs anything at squares that are *constrained* — one with no
//! perpendicular neighbour returns immediately. These synthetic boards lay
//! words in separate rows with gaps, which leaves only 24-71 constrained
//! cross-checks out of 232-410 possible, so they under-represent a real
//! interlocking board badly. This example first reported the sweep as ~2%
//! of a turn on that basis; replacing the per-letter `String` building it
//! measured went on to cut the *median* bot move from 0.59ms to 0.35ms,
//! which is nearer 40%. Use `engine_timing_bench` for absolute weight and
//! this only for the shape of the trend.

use std::time::Instant;

use rules_shared::{
    BoardCell, BoardState, Direction, FilledCell, Letter, Position, Rack, RuleCache, RulesEngine,
    VariantRules, WordListDictionary,
};

const REPS: usize = 5;

/// Boards of increasing fullness, built by applying the first `rows` of a
/// fixed list of real words.
///
/// Not legal positions — the vertical cross-words are nonsense — but the
/// quantities that drive the two phases are realistic: how many squares
/// are empty, how many are anchors, and how constrained they are. A
/// legal near-endgame board is fiddly to hand-build and would not change
/// the shape of the answer.
fn board_with_rows(rules: &VariantRules, rows: usize) -> BoardState {
    let mut board = BoardState::new(rules);
    let placements: &[(&str, u8, u8, Direction)] = &[
        ("TAZOS", 5, 4, Direction::Horizontal),
        ("JANAPERY", 3, 5, Direction::Horizontal),
        ("QUAXING", 2, 6, Direction::Horizontal),
        ("UNWIT", 2, 7, Direction::Horizontal),
        ("HATTIRED", 3, 8, Direction::Horizontal),
        ("NO", 3, 9, Direction::Horizontal),
        ("SOL", 3, 10, Direction::Horizontal),
        ("IRE", 3, 11, Direction::Horizontal),
        ("KEF", 2, 12, Direction::Horizontal),
        ("ODE", 2, 13, Direction::Horizontal),
        ("BRAVADO", 0, 0, Direction::Horizontal),
        ("CLIMATES", 0, 1, Direction::Horizontal),
        ("DUNGEONS", 0, 2, Direction::Horizontal),
        ("FRIGHTEN", 0, 3, Direction::Horizontal),
        ("GAZETTED", 4, 14, Direction::Horizontal),
        ("HOSPICE", 8, 9, Direction::Horizontal),
        ("JUNKYARD", 6, 10, Direction::Horizontal),
        ("KNOWABLE", 6, 11, Direction::Horizontal),
    ];
    for (word, x, y, direction) in placements.iter().take(rows) {
        for (offset, ch) in word.chars().enumerate() {
            let offset = offset as u8;
            let letter = Letter::from(ch);
            let pos = match direction {
                Direction::Horizontal => Position::new(x + offset, *y),
                Direction::Vertical => Position::new(*x, y + offset),
            };
            if pos.x >= rules.width || pos.y >= rules.height {
                continue;
            }
            board.set(
                pos,
                BoardCell::Filled(FilledCell {
                    letter,
                    is_blank: false,
                }),
            );
        }
    }
    board
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).expect("no NaNs"));
    values[values.len() / 2]
}

fn main() {
    let rules = VariantRules::official();
    let dictionary = WordListDictionary::new();
    let engine = RulesEngine {
        rules: &rules,
        dictionary: &dictionary,
    };
    let mut rack = Rack::default();
    for ch in ['E', 'A', 'R', 'T', 'S', 'N', 'I'] {
        rack.add_letter(Letter::from(ch));
    }

    println!("median of {REPS} runs, per board fullness\n");
    println!(
        "  {:>5} {:>7} {:>7} {:>8} {:>10} {:>10} {:>9}",
        "words", "empty", "constr", "moves", "sweep ms", "gen ms", "sweep %"
    );
    for rows in [3usize, 6, 10, 14, 18] {
        let board = board_with_rows(&rules, rows);
        phase_split(&engine, &rules, &dictionary, board, &rack, rows);
    }
}

fn phase_split(
    engine: &RulesEngine<'_, WordListDictionary>,
    rules: &VariantRules,
    dictionary: &WordListDictionary,
    board: BoardState,
    rack: &Rack,
    rows: usize,
) {
    let empty = (0..rules.height)
        .flat_map(|y| (0..rules.width).map(move |x| Position::new(x, y)))
        .filter(|pos| matches!(board.get(*pos), Some(BoardCell::Empty(_))))
        .count();

    // How many of those squares are actually *constrained* — the ones whose
    // cross-check runs the per-letter loop. An unconstrained square returns
    // early and costs nothing, so this, not `empty`, is what drives the
    // sweep's cost. Reported because it is the number that decides whether
    // a synthetic board resembles a real one: words laid in separate rows
    // with gaps leave most squares with no perpendicular neighbour at all,
    // which makes the sweep look far cheaper than it is in a real game.
    let mut probe = RuleCache::default();
    probe.recompute_all(&board, rules, dictionary);
    let constrained = (0..rules.height)
        .flat_map(|y| (0..rules.width).map(move |x| Position::new(x, y)))
        .map(|pos| {
            let cell = probe.cells[pos.to_index(BoardState::WIDTH)];
            usize::from(cell.horizontal.forms_cross_word())
                + usize::from(cell.vertical.forms_cross_word())
        })
        .sum::<usize>();

    // Phase 1: the full-board cross-check sweep `apply_move` performs.
    let cross_ms = median(
        (0..REPS)
            .map(|_| {
                let mut cache = RuleCache::default();
                let start = Instant::now();
                cache.recompute_all(&board, rules, dictionary);
                std::hint::black_box(&cache);
                start.elapsed().as_secs_f64() * 1000.0
            })
            .collect(),
    );

    // Phase 2: generation over the same position.
    let mut cache = RuleCache::default();
    cache.recompute_all(&board, rules, dictionary);
    let state = rules_shared::GameState { board, cache };

    let mut move_count = 0usize;
    let gen_ms = median(
        (0..REPS)
            .map(|_| {
                let start = Instant::now();
                let moves = engine.enumerate_legal_multi_tile_moves(&state, rack);
                move_count = moves.len();
                std::hint::black_box(moves.len());
                start.elapsed().as_secs_f64() * 1000.0
            })
            .collect(),
    );

    let total = cross_ms + gen_ms;
    println!(
        "  {rows:>5} {empty:>7} {constrained:>7} {move_count:>8} {cross_ms:>10.3} {gen_ms:>10.3} {:>8.1}%",
        100.0 * cross_ms / total
    );
}
