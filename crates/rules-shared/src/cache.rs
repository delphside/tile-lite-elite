use crate::board::{BoardCell, BoardState};
use crate::dictionary::Dictionary;
use crate::model::{
    Direction, Letter, LetterMask, MAX_ALPHABET_SIZE, Position, Score, VariantRules, mask_contains,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuleCache {
    pub cells: [CachedCell; 225],
    pub extents: LineExtents,
}

impl Default for RuleCache {
    fn default() -> Self {
        Self {
            cells: [CachedCell::default(); 225],
            extents: LineExtents::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CachedCell {
    pub horizontal: CrossCheck,
    pub vertical: CrossCheck,
    pub anchor_flags: AnchorFlags,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CrossCheck {
    #[default]
    Unconstrained,
    Constrained(ConstrainedCrossCheck),
}

impl CrossCheck {
    pub fn allows(self, letter: Letter) -> bool {
        match self {
            CrossCheck::Unconstrained => true,
            CrossCheck::Constrained(check) => mask_contains(check.allowed_mask, letter),
        }
    }

    /// Score of the cross word this cell would join, for a tile playing as
    /// `letter`. Legality is always judged on the letter — a blank has to
    /// spell a real word like any other tile — but a blank is worth
    /// nothing, so it scores the cell's blank total instead of the
    /// letter's.
    pub fn perpendicular_score(self, letter: Letter, is_blank: bool) -> Score {
        match self {
            CrossCheck::Unconstrained => 0,
            CrossCheck::Constrained(check) if is_blank => {
                if mask_contains(check.allowed_mask, letter) {
                    check.blank_score
                } else {
                    0
                }
            }
            CrossCheck::Constrained(check) => check.score_by_letter[letter.as_usize()],
        }
    }

    /// Whether a tile landing here joins a cross word at all, which is not
    /// the same question as whether that word scores: a blank crossing
    /// blanks forms a real word worth zero.
    pub fn forms_cross_word(self) -> bool {
        matches!(self, CrossCheck::Constrained(_))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConstrainedCrossCheck {
    pub allowed_mask: LetterMask,
    pub score_by_letter: [Score; MAX_ALPHABET_SIZE],
    /// What the cross word scores when the tile completing it is a blank.
    /// Letter-independent, since a blank adds nothing to the total no
    /// matter which letter it is standing in for.
    pub blank_score: Score,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AnchorFlags {
    pub horizontal_anchor: bool,
    pub vertical_anchor: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineExtents {
    pub row_left: [u8; 225],
    pub row_right: [u8; 225],
    pub col_top: [u8; 225],
    pub col_bottom: [u8; 225],
}

impl Default for LineExtents {
    fn default() -> Self {
        Self {
            row_left: [0; 225],
            row_right: [0; 225],
            col_top: [0; 225],
            col_bottom: [0; 225],
        }
    }
}

impl RuleCache {
    pub fn recompute_all<D: Dictionary>(
        &mut self,
        board: &BoardState,
        rules: &VariantRules,
        dictionary: &D,
    ) {
        self.recompute_extents(board, rules);
        self.recompute_anchor_flags(board, rules);

        for y in 0..rules.height {
            for x in 0..rules.width {
                let pos = Position::new(x, y);
                if matches!(board.get(pos), Some(BoardCell::Empty(_))) {
                    self.recompute_cross_check(
                        board,
                        pos,
                        Direction::Horizontal,
                        rules,
                        dictionary,
                    );
                    self.recompute_cross_check(board, pos, Direction::Vertical, rules, dictionary);
                }
            }
        }
    }

    pub fn recompute_cross_check<D: Dictionary>(
        &mut self,
        board: &BoardState,
        pos: Position,
        placement_direction: Direction,
        rules: &VariantRules,
        dictionary: &D,
    ) {
        let cross_check = compute_cross_check(board, pos, placement_direction, rules, dictionary);
        let index = pos.to_index(BoardState::WIDTH);
        match placement_direction {
            Direction::Horizontal => self.cells[index].horizontal = cross_check,
            Direction::Vertical => self.cells[index].vertical = cross_check,
        }
    }

    /// Recomputes only the cross-checks an applied move can have changed.
    ///
    /// A cell's cross-check depends on the contiguous run of tiles running
    /// *perpendicular* to the direction it is consulted for — see
    /// `compute_cross_check`, which walks `-placement_direction`. So a
    /// placed tile can only affect a cell that shares a row or column with
    /// it *and* has every cell between them occupied.
    ///
    /// Within a run every cell is occupied, so the only **empty** cells
    /// meeting that condition are the first empty cell at each **end** of
    /// the run. That is what makes this bounded by tiles placed rather than
    /// by board size: walk to the end of the run, take the next cell.
    ///
    /// And only *one* of a cell's two cross-checks is ever affected, never
    /// both — the run along an axis feeds the cross-check consulted for the
    /// other direction. For a move of *n* tiles that is at most `2 + 2n`
    /// recomputes, so 16 at a full rack, against 356 for a full sweep of a
    /// mid-game board (178 empty squares x 2 directions).
    ///
    /// `placed` are the positions just filled, and `board` must already
    /// hold them: the "every cell between is occupied" test is about the
    /// post-move board, since another tile from the same move may be what
    /// closed the gap.
    ///
    /// Cells the move just filled are left alone. They are no longer empty,
    /// so nothing reads their cross-checks — and a full sweep skips them
    /// too, so both paths agree by doing nothing.
    pub fn recompute_cross_checks_near<D: Dictionary>(
        &mut self,
        board: &BoardState,
        placed: &[Position],
        rules: &VariantRules,
        dictionary: &D,
    ) {
        // At most 2 + 2n entries, so a linear scan beats hashing.
        let mut done: Vec<(Position, Direction)> = Vec::with_capacity(16);

        for &pos in placed {
            for axis in [Direction::Horizontal, Direction::Vertical] {
                // The run along `axis` feeds the cross-check consulted for
                // the perpendicular direction.
                let affected = -axis;
                for end in run_end_neighbours(board, pos, axis, rules) {
                    if !done.contains(&(end, affected)) {
                        done.push((end, affected));
                        self.recompute_cross_check(board, end, affected, rules, dictionary);
                    }
                }
            }
        }
    }

    pub fn recompute_extents(&mut self, board: &BoardState, rules: &VariantRules) {
        for y in 0..rules.height {
            for x in 0..rules.width {
                let pos = Position::new(x, y);
                let index = pos.to_index(BoardState::WIDTH);

                self.extents.row_left[index] = find_extent(board, pos, Direction::Horizontal, true);
                self.extents.row_right[index] =
                    find_extent(board, pos, Direction::Horizontal, false);
                self.extents.col_top[index] = find_extent(board, pos, Direction::Vertical, true);
                self.extents.col_bottom[index] =
                    find_extent(board, pos, Direction::Vertical, false);
            }
        }
    }

    pub fn recompute_anchor_flags(&mut self, board: &BoardState, rules: &VariantRules) {
        let has_any_tiles = board_has_any_tiles(board, rules);

        for y in 0..rules.height {
            for x in 0..rules.width {
                let pos = Position::new(x, y);
                let index = pos.to_index(BoardState::WIDTH);

                self.cells[index].anchor_flags =
                    if matches!(board.get(pos), Some(BoardCell::Empty(_))) {
                        if !has_any_tiles {
                            AnchorFlags {
                                horizontal_anchor: pos
                                    == Position::new(rules.width / 2, rules.height / 2),
                                vertical_anchor: pos
                                    == Position::new(rules.width / 2, rules.height / 2),
                            }
                        } else {
                            let touching = touches_filled_neighbor(board, pos, rules);
                            AnchorFlags {
                                horizontal_anchor: touching,
                                vertical_anchor: touching,
                            }
                        }
                    } else {
                        AnchorFlags::default()
                    };
            }
        }
    }
}

/// The empty cells immediately beyond each end of the contiguous filled run
/// through `pos` along `direction` — at most two, fewer when a run reaches
/// the board edge.
///
/// These are exactly the cells whose run along `direction` the placement
/// changed: every cell *inside* the run is occupied and so has no
/// cross-check to update.
fn run_end_neighbours(
    board: &BoardState,
    pos: Position,
    direction: Direction,
    rules: &VariantRules,
) -> impl Iterator<Item = Position> {
    let mut ends = [None, None];

    for (slot, backward) in [(0usize, true), (1usize, false)] {
        let mut current = pos;
        loop {
            let next = if backward {
                current.try_step_backward(direction)
            } else {
                current.try_step_forward(direction, rules.width, rules.height)
            };
            let Some(next) = next else { break };
            match board.get(next) {
                Some(BoardCell::Filled(_)) => current = next,
                Some(BoardCell::Empty(_)) => {
                    ends[slot] = Some(next);
                    break;
                }
                None => break,
            }
        }
    }

    ends.into_iter().flatten()
}

fn find_extent(board: &BoardState, pos: Position, direction: Direction, backward: bool) -> u8 {
    let mut current = pos;

    loop {
        let next = if backward {
            current.try_step_backward(direction)
        } else {
            current.try_step_forward(direction, BoardState::WIDTH as u8, BoardState::HEIGHT as u8)
        };

        let Some(next) = next else {
            break;
        };

        match board.get(next) {
            Some(BoardCell::Filled(_)) => current = next,
            _ => break,
        }
    }

    match direction {
        Direction::Horizontal => current.x,
        Direction::Vertical => current.y,
    }
}

pub(crate) fn board_has_any_tiles(board: &BoardState, rules: &VariantRules) -> bool {
    for y in 0..rules.height {
        for x in 0..rules.width {
            if matches!(board.get(Position::new(x, y)), Some(BoardCell::Filled(_))) {
                return true;
            }
        }
    }
    false
}

fn touches_filled_neighbor(board: &BoardState, pos: Position, rules: &VariantRules) -> bool {
    for direction in [Direction::Horizontal, Direction::Vertical] {
        if let Some(next) = pos.try_step_backward(direction)
            && matches!(board.get(next), Some(BoardCell::Filled(_)))
        {
            return true;
        }

        if let Some(next) = pos.try_step_forward(direction, rules.width, rules.height)
            && matches!(board.get(next), Some(BoardCell::Filled(_)))
        {
            return true;
        }
    }

    false
}

pub fn compute_cross_check<D: Dictionary>(
    board: &BoardState,
    pos: Position,
    placement_direction: Direction,
    rules: &VariantRules,
    dictionary: &D,
) -> CrossCheck {
    let Some(BoardCell::Empty(empty_cell)) = board.get(pos).copied() else {
        return CrossCheck::Unconstrained;
    };

    let perpendicular = -placement_direction;
    let mut before = Vec::new();
    let mut after = Vec::new();
    let mut surrounding_score: Score = 0;

    let mut current = pos;
    while let Some(next) = current.try_step_backward(perpendicular) {
        match board.filled_letter(next) {
            Some((letter, is_blank)) => {
                before.push(letter);
                if !is_blank {
                    surrounding_score += rules.letter_values[letter.as_usize()] as Score;
                }
                current = next;
            }
            None => break,
        }
    }

    current = pos;
    while let Some(next) = current.try_step_forward(perpendicular, rules.width, rules.height) {
        match board.filled_letter(next) {
            Some((letter, is_blank)) => {
                after.push(letter);
                if !is_blank {
                    surrounding_score += rules.letter_values[letter.as_usize()] as Score;
                }
                current = next;
            }
            None => break,
        }
    }

    if before.is_empty() && after.is_empty() {
        return CrossCheck::Unconstrained;
    }

    // `before` was collected walking backwards from the square, so flip it
    // into reading order — the candidate cross word is before + letter +
    // after.
    before.reverse();

    // One batch question rather than one per letter. Every candidate shares
    // this prefix and this suffix, so a dictionary with a prefix structure
    // walks the shared part once; the trait's default still builds a word
    // per letter, which is what this used to do inline.
    let allowed_mask = dictionary.allowed_letters(&before, &after, &rules.alphabet);

    let mut score_by_letter = [0; MAX_ALPHABET_SIZE];
    for letter in rules.letters() {
        if mask_contains(allowed_mask, letter) {
            let central_score = (rules.letter_values[letter.as_usize()] as Score)
                * empty_cell.premium.letter_multiplier() as Score;
            score_by_letter[letter.as_usize()] =
                (surrounding_score + central_score) * empty_cell.premium.word_multiplier() as Score;
        }
    }

    CrossCheck::Constrained(ConstrainedCrossCheck {
        allowed_mask,
        score_by_letter,
        // A blank contributes nothing whichever letter it stands in for,
        // so the whole cross word is worth the surrounding tiles alone —
        // one value for the cell rather than one per letter. The square's
        // letter multiplier is irrelevant against a zero-value tile; its
        // word multiplier still applies to what the neighbours are worth.
        blank_score: surrounding_score * empty_cell.premium.word_multiplier() as Score,
    })
}

#[cfg(test)]
mod tests {
    use super::{CrossCheck, RuleCache, compute_cross_check};
    use crate::board::{BoardCell, BoardState, EmptyCell, FilledCell};
    use crate::dictionary::WordListDictionary;
    use crate::model::{Direction, Letter, Position, Premium, VariantRules};

    fn sample_rules() -> VariantRules {
        VariantRules::official()
    }

    #[test]
    fn unconstrained_when_no_perpendicular_neighbors() {
        let board = BoardState::default();
        let rules = sample_rules();
        let dictionary = WordListDictionary::new();
        let pos = Position::new(7, 7);

        let cross_check =
            compute_cross_check(&board, pos, Direction::Horizontal, &rules, &dictionary);

        assert!(matches!(cross_check, CrossCheck::Unconstrained));
    }

    #[test]
    fn constrained_when_perpendicular_word_must_be_valid() {
        let mut board = BoardState::default();
        let rules = sample_rules();
        let dictionary = WordListDictionary::new();
        let pos = Position::new(7, 7);

        board.set(
            Position::new(7, 6),
            BoardCell::Filled(FilledCell {
                letter: Letter::from('C'),
                is_blank: false,
            }),
        );
        board.set(
            Position::new(7, 8),
            BoardCell::Filled(FilledCell {
                letter: Letter::from('T'),
                is_blank: false,
            }),
        );
        board.set(
            pos,
            BoardCell::Empty(EmptyCell {
                premium: Premium::Blank,
            }),
        );

        let cross_check =
            compute_cross_check(&board, pos, Direction::Horizontal, &rules, &dictionary);

        match cross_check {
            CrossCheck::Constrained(check) => {
                assert!(super::CrossCheck::Constrained(check).allows(Letter::from('A')));
                assert!(!super::CrossCheck::Constrained(check).allows(Letter::from('Z')));
                assert_eq!(check.score_by_letter[Letter::from('A').as_usize()], 5);
            }
            CrossCheck::Unconstrained => panic!("expected constrained cross-check"),
        }
    }

    #[test]
    fn center_is_anchor_on_first_move() {
        let board = BoardState::default();
        let rules = sample_rules();
        let mut cache = RuleCache::default();

        cache.recompute_anchor_flags(&board, &rules);

        let center = cache.cells[Position::new(7, 7).to_index(BoardState::WIDTH)].anchor_flags;
        let corner = cache.cells[Position::new(0, 0).to_index(BoardState::WIDTH)].anchor_flags;

        assert!(center.horizontal_anchor);
        assert!(center.vertical_anchor);
        assert!(!corner.horizontal_anchor);
        assert!(!corner.vertical_anchor);
    }

    #[test]
    fn touching_cell_becomes_anchor_after_placement() {
        let mut board = BoardState::default();
        let rules = sample_rules();
        let mut cache = RuleCache::default();

        board.set(
            Position::new(7, 7),
            BoardCell::Filled(FilledCell {
                letter: Letter::from('A'),
                is_blank: false,
            }),
        );

        cache.recompute_anchor_flags(&board, &rules);

        let anchor = cache.cells[Position::new(7, 6).to_index(BoardState::WIDTH)].anchor_flags;
        assert!(anchor.horizontal_anchor);
        assert!(anchor.vertical_anchor);
    }
}
