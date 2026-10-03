pub mod board;
pub mod cache;
pub mod dictionary;
pub mod format;
pub mod generate;
pub mod model;
pub mod score;
pub mod tiered;
pub mod validate;
pub mod wordlists;

pub use board::{BoardCell, BoardState, EmptyCell, FilledCell};
pub use cache::{
    AnchorFlags, CachedCell, ConstrainedCrossCheck, CrossCheck, LineExtents, RuleCache,
};
#[cfg(not(target_arch = "wasm32"))]
pub use dictionary::build_all_dictionaries;
pub use dictionary::{Dictionary, WordListDictionary, alphabet_by_name};
#[cfg(not(target_arch = "wasm32"))]
pub use dictionary::{
    ENABLE2K, GERMAN, SOWPODS, SPANISH, dictionary_by_name, enable2k_word_list, german_word_list,
    is_word, sowpods_word_list, spanish_word_list,
};
pub use format::format_move_error;
pub use generate::MoveGenerator;
pub use model::{
    Alphabet, CrossWordPreview, Direction, Grapheme, Letter, LetterMask, MAX_ALPHABET_SIZE,
    MoveCandidate, MoveError, MovePreview, MoveScore, Position, Premium, Rack, Score, Tile,
    TilePlacement, ValidatedMove, VariantRules,
};
pub use tiered::{Child, Cursor, PackedChild, Step, TieredCursor, TieredDictionary};
pub use validate::{GameState, MoveValidator, RulesEngine, RulesPosition};
