use crate::{
    app::{MovePreviewView, RackTileView, StagedPlacementView},
    components::{board_view::BoardView, rack_view::RackView},
    edition_label::edition_label,
};
use api::{DirectionDto, GameStateDto, GameStatus, TileDto};
use dioxus::prelude::*;
use std::collections::HashSet;
use std::rc::Rc;

#[component]
pub fn Home(
    game: GameStateDto,
    is_live: bool,
    is_loading: bool,
    /// `Some((before, after))` only when this game just moved the
    /// viewer's own rating — see `ParticipantDto.rating_before`/
    /// `rating_after`'s doc comment for exactly when that is.
    my_rating_delta: Option<(f64, f64)>,
    info_message: Option<String>,
    error_message: Option<String>,
    rack_tiles: Vec<RackTileView>,
    on_shuffle_rack: EventHandler<()>,
    can_view_rack: bool,
    staged_placements: Vec<StagedPlacementView>,
    can_stage_moves: bool,
    selected_cell: Option<usize>,
    can_toggle_direction: bool,
    current_typing_direction: DirectionDto,
    on_toggle_direction: EventHandler<()>,
    on_drag_rack_tile: EventHandler<usize>,
    on_drag_end_rack_tile: EventHandler<()>,
    on_drop_rack_tile: EventHandler<usize>,
    on_drag_staged_tile: EventHandler<usize>,
    on_drag_end_staged_tile: EventHandler<usize>,
    on_drop_board_cell: EventHandler<usize>,
    on_select_cell: EventHandler<usize>,
    /// Take me to the unread messages, switching game if they are elsewhere.
    on_show_unread: EventHandler<()>,
    on_move_selection: EventHandler<(DirectionDto, bool, bool)>,
    on_click_rack_tile: EventHandler<usize>,
    on_type_letter: EventHandler<char>,
    on_backspace: EventHandler<()>,
    on_delete: EventHandler<()>,
    on_clear_staged: EventHandler<()>,
    on_remove_staged: EventHandler<usize>,
    on_set_blank_letter: EventHandler<String>,
    selected_blank_letter: Option<String>,
    staged_preview: Option<MovePreviewView>,
    is_your_turn: bool,
    can_pass: bool,
    on_pass: EventHandler<()>,
    can_resign: bool,
    on_resign: EventHandler<()>,
    can_submit_manual: bool,
    on_submit_manual: EventHandler<()>,
    exchange_mode: bool,
    exchange_selected: HashSet<usize>,
    can_toggle_exchange: bool,
    on_toggle_exchange_mode: EventHandler<()>,
    on_toggle_exchange_tile: EventHandler<usize>,
    can_confirm_exchange: bool,
    on_confirm_exchange: EventHandler<()>,
    on_cancel_exchange: EventHandler<()>,
) -> Element {
    let has_rack = can_view_rack;
    let has_rack_tiles = !rack_tiles.is_empty();
    let is_active = game.status == GameStatus::Active;

    // Resolved once and reused everywhere this component needs the active
    // game's actual alphabet/letter values, rather than assuming the
    // standard Latin 26 — different editions (German, Spanish, ...)
    // genuinely differ here. Retired-aware: this is an already-created
    // game, which may predate an edition's withdrawal from the picker.
    // Falls back to `official()` only for an edition name this client
    // build doesn't recognize, which shouldn't happen for a real loaded
    // game.
    let rules = rules_shared::VariantRules::by_name_including_retired(&game.variant)
        .unwrap_or_else(rules_shared::VariantRules::official);

    // Show blank picker when there is a staged blank tile still needing a letter.
    let has_unresolved_blank = staged_placements
        .iter()
        .any(|p| matches!(p.tile, TileDto::Blank { acting_as: None }));

    let selected_blank_text = selected_blank_letter
        .clone()
        .unwrap_or_else(|| "choose a letter".to_string());

    let blank_letter_buttons = rules
        .letters()
        .map(|letter| rules.letter_grapheme(letter).to_string())
        .map(|letter| {
            let class_name = if selected_blank_letter.as_deref() == Some(letter.as_str()) {
                "blank-letter-button blank-letter-button-active"
            } else {
                "blank-letter-button"
            };
            let letter_for_click = letter.clone();
            rsx! {
                button {
                    key: "{letter}",
                    class: "{class_name}",
                    onclick: move |_| on_set_blank_letter.call(letter_for_click.clone()),
                    "{letter}"
                }
            }
        });

    // Keyboard typing (letter placement, backspace) only works while this
    // element has DOM focus. Clicking a board cell reclaims focus here
    // explicitly (see `on_select_cell` below) since a plain, non-form
    // element losing focus to e.g. a turn-action button is otherwise a dead
    // end — nothing else would naturally hand focus back.
    let mut keyboard_focus: Signal<Option<Rc<MountedData>>> = use_signal(|| None);
    // Resigning ends the game outright, so it's gated behind an explicit
    // confirmation rather than firing straight off the button click.
    let mut confirming_resign = use_signal(|| false);
    // Cloned for the `move` keydown closure below — `rules` itself is
    // still needed afterward (passed into `BoardView`/`RackView`).
    let rules_for_keydown = rules.clone();

    rsx! {
        section {
            class: "workspace-main",
            tabindex: "0",
            onmounted: move |event| {
                keyboard_focus.set(Some(event.data()));
            },
            onkeydown: move |event| {
                if event.key() == Key::Enter {
                    // Works regardless of cursor position — once tiles are
                    // staged, Enter submits them the same as clicking Play.
                    if can_submit_manual {
                        event.prevent_default();
                        on_submit_manual.call(());
                    }
                    return;
                }
                if selected_cell.is_none() {
                    return;
                }
                // Holding any of Ctrl/Shift/Alt while arrowing lets the cursor
                // step *onto* occupied cells (a played letter, or a tile staged
                // earlier this turn) instead of skipping past them — e.g. to
                // land on a specific staged tile and Delete it. Plain arrows
                // keep the skip-to-next-free-cell behavior.
                let onto_occupied = event
                    .modifiers()
                    .intersects(Modifiers::CONTROL | Modifiers::SHIFT | Modifiers::ALT);
                match event.key() {
                    Key::ArrowLeft => {
                        event.prevent_default();
                        on_move_selection.call((DirectionDto::Horizontal, false, onto_occupied));
                    }
                    Key::ArrowRight => {
                        event.prevent_default();
                        on_move_selection.call((DirectionDto::Horizontal, true, onto_occupied));
                    }
                    Key::ArrowUp => {
                        event.prevent_default();
                        on_move_selection.call((DirectionDto::Vertical, false, onto_occupied));
                    }
                    Key::ArrowDown => {
                        event.prevent_default();
                        on_move_selection.call((DirectionDto::Vertical, true, onto_occupied));
                    }
                    Key::Character(text) if text == " " => {
                        if can_toggle_direction {
                            event.prevent_default();
                            on_toggle_direction.call(());
                        }
                    }
                    Key::Character(text) if text.chars().count() == 1 => {
                        if let Some(ch) = text.chars().next() {
                            let upper = ch.to_uppercase().next().unwrap_or(ch);
                            if rules_for_keydown
                                .alphabet
                                .to_letter(&upper.to_string())
                                .is_some()
                            {
                                event.prevent_default();
                                on_type_letter.call(upper);
                            }
                        }
                    }
                    Key::Backspace => {
                        event.prevent_default();
                        on_backspace.call(());
                    }
                    Key::Delete => {
                        event.prevent_default();
                        on_delete.call(());
                    }
                    _ => {}
                }
            },
            div { class: "status-strip",
                if is_live {
                    span { class: "meta-chip", "{edition_label(&game.variant)}" }
                    span { class: "meta-chip", "{format_status(&game)}" }
                }
                if is_active {
                    span { class: "meta-chip", "Turn: {current_turn_name(&game)}" }
                    span { class: "meta-chip", "{crate::time_format::format_time_remaining(game.turn_started_at, game.move_time_limit_seconds)}" }
                }
                if is_loading {
                    span { class: "meta-chip", "Working..." }
                }
            }
            if let Some(summary) = finished_game_summary(&game) {
                p { class: "game-over-banner",
                    "{summary}"
                    if let Some((before, after)) = my_rating_delta {
                        span {
                            class: if after >= before { "rating-delta rating-delta-up" } else { "rating-delta rating-delta-down" },
                            {
                                let delta = after - before;
                                let sign = if delta >= 0.0 { "+" } else { "" };
                                format!("Your rating: {before:.0} → {after:.0} ({sign}{delta:.0})")
                            }
                        }
                    }
                }
            }
            if !has_rack {
                if let Some(error_message) = error_message.clone() {
                    p { class: "error-banner", "{error_message}" }
                } else if let Some(info_message) = info_message.clone() {
                    p { class: "status-banner", "{info_message}" }
                }
            }

            div { class: "board-panel",
                BoardView {
                    board: game.board.clone(),
                    staged_placements: staged_placements.clone(),
                    last_move_cells: last_move_board_indices(&game.moves),
                    can_stage_moves,
                    selected_cell,
                    letter_values: rules.letter_values,
                    alphabet: rules.alphabet.clone(),
                    on_drop_tile: on_drop_board_cell,
                    on_remove_staged,
                    on_drag_staged_tile,
                    on_drag_end_staged_tile,
                    on_select_cell: move |index| {
                        if let Some(handle) = keyboard_focus() {
                            spawn(async move {
                                let _ = handle.set_focus(true).await;
                            });
                        }
                        on_select_cell.call(index);
                    },
                }
            }

            if has_rack {
                div { class: "rack-panel",
                    // Scores, where the eye already is. On a phone the seats
                    // table sits far above the board — see issue #3.
                    //
                    // Only once play has started. A `Waiting` game has
                    // nothing to report but a row of zeros, and the empty
                    // board shown before any game is opened is backed by a
                    // placeholder participant literally named "Open a game"
                    // — which this row rendered as "● Oag 0", since the
                    // abbreviation is initials and that is three words.
                    {
                        let names: Vec<String> = game
                            .participants
                            .iter()
                            .map(|participant| participant.display_name.clone())
                            .collect();
                        let labels = seat_labels(&names);
                        let entries = game.participants.iter().zip(labels).map(|(participant, label)| {
                            let active = participant.seat_number == game.current_seat;
                            rsx! {
                                span {
                                    key: "{participant.seat_number}",
                                    class: if active { "rack-score rack-score-active" } else { "rack-score" },
                                    span { class: "rack-score-name", "{label}" }
                                    span { class: "rack-score-value", "{participant.score}" }
                                    if let Some(delta) = last_move_delta(&game.moves, participant.seat_number) {
                                        span { class: "rack-score-delta", "{delta:+}" }
                                    }
                                }
                            }
                        });
                        // Seats only once play has started — a `Waiting`
                        // game has nothing but zeros to report, and the
                        // empty board before any game is opened is backed
                        // by a placeholder participant named "Open a game",
                        // which this rendered as "● Oag 0".
                        //
                        // The bag count always shows. It moved here from the
                        // rack row, where as a non-shrinking flex item it
                        // took ~94px from the tiles — enough to push a
                        // seven-tile rack onto a second line on a phone. It
                        // belongs with the scores anyway: both are state you
                        // glance at rather than act on.
                        let started = game.status != api::GameStatus::Waiting;
                        rsx! {
                            div { class: "rack-scores",
                                if started { {entries} }
                                // Unread chat, where the eye already is. On a
                                // phone the chat panel can be off screen
                                // entirely, and an indicator only in the games
                                // list tells nobody anything while they are
                                // playing. Same signal as the chat panel's own,
                                // so the two cannot disagree.
                                if crate::app::HAS_UNREAD_CHAT() {
                                    // A button, not a label: it says there is a
                                    // message somewhere below, so it should be
                                    // the way to get there. Scrolling the panel
                                    // into view is also what marks the message
                                    // read, since the seen clock only counts
                                    // time the chat is actually visible.
                                    button {
                                        // Colour says *where*: gold for this
                                        // game, clay for another — the same
                                        // colours the game rows use, so the two
                                        // read as one signal rather than two.
                                        class: if crate::app::UNREAD_IS_THIS_GAME() {
                                            "rack-scores-unread rack-scores-unread-here"
                                        } else {
                                            "rack-scores-unread rack-scores-unread-elsewhere"
                                        },
                                        title: if crate::app::UNREAD_IS_THIS_GAME() {
                                            "New message in this game — click to read it"
                                        } else {
                                            "New message in another game"
                                        },
                                        onclick: move |_| on_show_unread.call(()),
                                        "✉"
                                    }
                                }
                                span { class: "rack-scores-bag", "Bag {game.bag_count}" }
                            }
                        }
                    }
                    if has_unresolved_blank {
                        div { class: "blank-picker",
                            p { class: "composer-copy",
                                "Blank tile — choose a letter: {selected_blank_text}"
                            }
                            div { class: "blank-picker-grid", {blank_letter_buttons} }
                        }
                    }
                    // The one message slot for this composer — a fixed
                    // size regardless of which of these is showing, so it
                    // never shifts the tiles below it. Priority: the live
                    // preview of what's currently staged, else a submit
                    // error, else a plain status line (whose turn it is).
                    div { class: "preview-slot",
                        if let Some(preview) = staged_preview {
                            div { class: if preview.is_legal { "preview-banner" } else { "preview-banner preview-banner-error" },
                                div { class: "preview-banner-top",
                                    h3 { class: "preview-title", "{preview.headline}" }
                                    if let Some(score) = preview.score {
                                        span { class: "preview-score", "+{score}" }
                                    }
                                }
                                if preview.is_legal && !preview.detail.is_empty() {
                                    p { class: "composer-copy", "{preview.detail}" }
                                }
                            }
                        } else if let Some(error_message) = error_message.clone() {
                            div { class: "preview-banner preview-banner-error",
                                p { class: "composer-copy", "{error_message}" }
                            }
                        } else if is_active {
                            div { class: "preview-banner",
                                p { class: "composer-copy",
                                    // The last move's own already-formatted
                                    // description ("Alice played CARROT for
                                    // 24", "Bob passed", ...) leads, with the
                                    // turn indicator right after it — e.g.
                                    // "Hazel played RUN for 10. Waiting for
                                    // John." — rather than replacing it, so
                                    // this slot carries both what just
                                    // happened and whose turn it is now.
                                    if let Some(last_move) = game.moves.last() {
                                        "{last_move.description}. "
                                    }
                                    if is_your_turn {
                                        "Your turn"
                                    } else {
                                        "Waiting for {current_turn_name(&game)}"
                                    }
                                }
                            }
                        }
                    }
                    div { class: "rack-row",
                        RackView {
                            tiles: rack_tiles,
                            can_stage_moves,
                            exchange_mode,
                            exchange_selected: exchange_selected.clone(),
                            letter_values: rules.letter_values,
                            alphabet: rules.alphabet.clone(),
                            on_drag_start: on_drag_rack_tile,
                            on_drag_end: on_drag_end_rack_tile,
                            on_drop_tile: on_drop_rack_tile,
                            on_click_tile: on_click_rack_tile,
                            on_toggle_exchange_tile,
                        }
                    }

                    div { class: "turn-actions",
                        div { class: "turn-actions-left",
                            if has_rack_tiles {
                                button {
                                    class: "direction-button direction-button-muted",
                                    onclick: move |_| on_shuffle_rack.call(()),
                                    "Shuffle"
                                }
                            }
                            if !staged_placements.is_empty() {
                                button {
                                    class: "direction-button direction-button-muted",
                                    onclick: move |_| on_clear_staged.call(()),
                                    "Clear"
                                }
                            }
                            if can_toggle_direction {
                                button {
                                    class: "direction-button direction-button-muted",
                                    title: "Change which way this word reads — same as pressing space bar",
                                    onclick: move |_| on_toggle_direction.call(()),
                                    {
                                        match current_typing_direction {
                                            DirectionDto::Horizontal => "⇄ Switch to Down",
                                            DirectionDto::Vertical => "⇄ Switch to Across",
                                        }
                                    }
                                }
                            }
                        }
                        div { class: "turn-actions-buttons",
                            if is_active && exchange_mode {
                                button {
                                    class: "toggle-button toggle-button-muted",
                                    disabled: is_loading,
                                    onclick: move |_| on_cancel_exchange.call(()),
                                    "Cancel"
                                }
                                button {
                                    class: "toggle-button",
                                    disabled: is_loading || !can_confirm_exchange,
                                    onclick: move |_| on_confirm_exchange.call(()),
                                    "Confirm Exchange ({exchange_selected.len()})"
                                }
                            }
                            if is_active && !exchange_mode {
                                button {
                                    class: "toggle-button toggle-button-muted",
                                    disabled: is_loading || !can_pass,
                                    onclick: move |_| on_pass.call(()),
                                    "Pass"
                                }
                                button {
                                    class: "toggle-button toggle-button-muted",
                                    disabled: is_loading || !can_toggle_exchange,
                                    onclick: move |_| on_toggle_exchange_mode.call(()),
                                    "Exchange"
                                }
                                button {
                                    class: "toggle-button",
                                    disabled: is_loading || !can_submit_manual,
                                    onclick: move |_| on_submit_manual.call(()),
                                    "Play"
                                }
                            }
                        }
                        if is_active && !exchange_mode {
                            div { class: "turn-actions-resign",
                                button {
                                    class: "toggle-button toggle-button-muted resign-button",
                                    disabled: is_loading || !can_resign,
                                    onclick: move |_| confirming_resign.set(true),
                                    "Resign"
                                }
                            }
                        }
                    }
                }
            }

            if confirming_resign() {
                div { class: "modal-backdrop",
                    div { class: "modal-card",
                        h2 { class: "modal-title", "Resign this game?" }
                        p { class: "modal-copy", "This ends the game immediately — there's no undoing it." }
                        div { class: "modal-actions",
                            button {
                                class: "toggle-button toggle-button-muted",
                                onclick: move |_| confirming_resign.set(false),
                                "Cancel"
                            }
                            button {
                                class: "toggle-button",
                                onclick: move |_| {
                                    confirming_resign.set(false);
                                    on_resign.call(());
                                },
                                "Yes, resign"
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Board squares to highlight as "the last move" — whatever `moves.last()`
/// placed, which is empty for a pass/exchange/resign/timeout (nothing on
/// the board changed) rather than falling back to an earlier placement.
fn last_move_board_indices(moves: &[api::MoveRecordDto]) -> HashSet<usize> {
    moves
        .last()
        .map(|record| {
            record
                .positions
                .iter()
                .map(|p| p.y as usize * crate::app::BOARD_WIDTH + p.x as usize)
                .collect()
        })
        .unwrap_or_default()
}

/// The persistent "who won, and why" banner shown once a game finishes —
/// previously the only way to tell was to notice the status badge in the
/// games list and work the scores out by hand. `None` while the game is
/// still in progress.
fn finished_game_summary(game: &GameStateDto) -> Option<String> {
    // An aborted game is terminal but not a result — no winner to announce,
    // just a note that the creator called it off.
    if game.status == GameStatus::Aborted {
        return Some("Game aborted by the creator.".to_string());
    }
    if game.status != GameStatus::Finished {
        return None;
    }

    let seat_name = |seat: u8| -> &str {
        game.participants
            .iter()
            .find(|p| p.seat_number == seat)
            .map(|p| p.display_name.as_str())
            .unwrap_or("Someone")
    };

    let outcome = match game.winner_seat {
        Some(seat) => format!("Game over — {} won!", seat_name(seat)),
        None => "Game over — it's a tie!".to_string(),
    };

    match (game.final_bonus_seat, game.final_bonus_points) {
        (Some(seat), Some(points)) if points > 0 => Some(format!(
            "{outcome} {} went out and picked up a {points}-point bonus from the other players' racks.",
            seat_name(seat)
        )),
        _ => Some(outcome),
    }
}

fn current_turn_name(game: &GameStateDto) -> &str {
    game.participants
        .iter()
        .find(|participant| participant.seat_number == game.current_seat)
        .map(|participant| participant.display_name.as_str())
        .unwrap_or("Unknown")
}

fn format_status(game: &GameStateDto) -> &'static str {
    match game.status {
        api::GameStatus::Waiting => "Waiting",
        api::GameStatus::Active => "Playing",
        api::GameStatus::Finished => "Finished",
        api::GameStatus::Aborted => "Aborted",
    }
}

/// Short labels for the seats, unique within this game.
///
/// The scores row has to fit several seats on a phone, so `Greedy 1` becomes
/// `G1` and `Steve45` becomes `S` — the first character of each
/// whitespace-separated word. That handles the common shape (a human plus
/// numbered bots) without inventing anything to read.
///
/// If any two seats would end up with the same label, *every* seat falls
/// back to its full name rather than lengthening only the pair that clashed.
/// Abbreviating some names and not others is harder to read than
/// abbreviating none, and an ambiguous label is worse than a long one when
/// the whole point is to tell at a glance who is winning.
fn seat_labels(names: &[String]) -> Vec<String> {
    let short: Vec<String> = names
        .iter()
        .map(|name| {
            name.split_whitespace()
                .filter_map(|word| word.chars().next())
                .collect::<String>()
        })
        .collect();

    let mut seen: Vec<&str> = short.iter().map(String::as_str).collect();
    seen.sort_unstable();
    let all_distinct = {
        let before = seen.len();
        seen.dedup();
        seen.len() == before
    };

    if all_distinct && short.iter().all(|label| !label.is_empty()) {
        short
    } else {
        names.to_vec()
    }
}

/// The score a seat took on its most recent move, for the scores row.
///
/// A narrower question than the seats table's `last_move_cell`, which also
/// wants the word, the move type and the elapsed time. Here only the number
/// matters: the totals say who is winning, and this says who is *moving*.
///
/// `None` for a seat that has not played yet, which is different from a seat
/// that scored nothing — a pass gives `Some(0)`, and showing "+0" says
/// something true that a blank would not.
fn last_move_delta(moves: &[api::MoveRecordDto], seat_number: u8) -> Option<i32> {
    moves
        .iter()
        .rev()
        .find(|record| record.seat_number == seat_number)
        .map(|record| record.score_delta)
}

#[cfg(test)]
mod tests {

    fn move_by(seat_number: u8, score_delta: i32) -> api::MoveRecordDto {
        api::MoveRecordDto {
            move_number: 0,
            seat_number,
            move_type: "place".to_string(),
            main_word: None,
            score_delta,
            elapsed_us: None,
            positions: Vec::new(),
            description: String::new(),
        }
    }

    #[test]
    fn last_move_delta_takes_the_seats_most_recent_move() {
        let moves = vec![move_by(0, 14), move_by(1, 22), move_by(0, 39)];
        assert_eq!(last_move_delta(&moves, 0), Some(39));
        assert_eq!(last_move_delta(&moves, 1), Some(22));
    }

    /// A seat that has not played is not the same as one that scored
    /// nothing, and the row shows "+0" for the second.
    #[test]
    fn last_move_delta_distinguishes_no_move_from_a_scoreless_one() {
        let moves = vec![move_by(0, 0)];
        assert_eq!(last_move_delta(&moves, 0), Some(0));
        assert_eq!(last_move_delta(&moves, 1), None);
    }

    #[test]
    fn seat_labels_abbreviate_to_initials() {
        let names = vec![
            "Steve45".to_string(),
            "Greedy 1".to_string(),
            "Greedy 2".to_string(),
            "Greedy 3".to_string(),
        ];
        assert_eq!(seat_labels(&names), vec!["S", "G1", "G2", "G3"]);
    }

    /// Abbreviating only the names that happen not to clash would leave a
    /// row mixing "S" with "Steve" and "Sam", which reads worse than either
    /// extreme. All or nothing.
    #[test]
    fn seat_labels_fall_back_to_full_names_when_any_would_collide() {
        let names = vec!["Steve".to_string(), "Sam".to_string()];
        assert_eq!(seat_labels(&names), vec!["Steve", "Sam"]);
    }

    #[test]
    fn seat_labels_handle_multi_word_and_non_ascii_names() {
        let names = vec!["Mary Jane Smith".to_string(), "José".to_string()];
        assert_eq!(seat_labels(&names), vec!["MJS", "J"]);
    }

    /// A name that is only whitespace yields an empty label, which would be
    /// an invisible seat. Falling back keeps every seat visible.
    #[test]
    fn seat_labels_fall_back_when_a_name_yields_nothing() {
        let names = vec!["   ".to_string(), "Greedy 1".to_string()];
        assert_eq!(seat_labels(&names), vec!["   ", "Greedy 1"]);
    }
    use super::*;

    fn place_record(positions: Vec<api::PositionDto>) -> api::MoveRecordDto {
        api::MoveRecordDto {
            move_number: 1,
            seat_number: 0,
            move_type: "place".to_string(),
            main_word: Some("CAT".to_string()),
            score_delta: 10,
            positions,
            description: String::new(),
            elapsed_us: None,
        }
    }

    fn pass_record() -> api::MoveRecordDto {
        api::MoveRecordDto {
            move_number: 2,
            seat_number: 1,
            move_type: "pass".to_string(),
            main_word: None,
            score_delta: 0,
            positions: Vec::new(),
            description: String::new(),
            elapsed_us: None,
        }
    }

    #[test]
    fn highlights_the_last_placed_move_s_squares() {
        let moves = vec![place_record(vec![
            api::PositionDto { x: 7, y: 7 },
            api::PositionDto { x: 8, y: 7 },
        ])];
        let indices = last_move_board_indices(&moves);
        assert_eq!(indices, HashSet::from([7 * 15 + 7, 7 * 15 + 8]));
    }

    #[test]
    fn a_trailing_pass_has_nothing_to_highlight_even_after_an_earlier_placement() {
        let moves = vec![
            place_record(vec![api::PositionDto { x: 7, y: 7 }]),
            pass_record(),
        ];
        assert!(last_move_board_indices(&moves).is_empty());
    }

    #[test]
    fn no_moves_yet_highlights_nothing() {
        assert!(last_move_board_indices(&[]).is_empty());
    }

    fn participant(seat_number: u8, display_name: &str, score: i32) -> api::ParticipantDto {
        api::ParticipantDto {
            seat_number,
            kind: api::SeatKind::Human,
            display_name: display_name.to_string(),
            player_id: None,
            engine_id: None,
            score,
            invitation_status: None,
            invited_email: None,
            rating_before: None,
            rating_after: None,
            current_rating: None,
            resigned: false,
        }
    }

    fn finished_game(
        winner_seat: Option<u8>,
        final_bonus_seat: Option<u8>,
        final_bonus_points: Option<i32>,
        participants: Vec<api::ParticipantDto>,
    ) -> GameStateDto {
        GameStateDto {
            id: "game-1".to_string(),
            version: 0,
            status: GameStatus::Finished,
            creator_player_id: None,
            variant: "official".to_string(),
            language: "sowpods".to_string(),
            board_layout: "official".to_string(),
            turn_number: 5,
            current_seat: 0,
            winner_seat,
            final_bonus_seat,
            final_bonus_points,
            bag_count: 0,
            move_time_limit_seconds: 0,
            turn_started_at: 0,
            participants,
            board: Vec::new(),
            racks: Vec::new(),
            moves: Vec::new(),
            messages: Vec::new(),
        }
    }

    #[test]
    fn in_progress_game_has_no_summary() {
        let mut game = finished_game(Some(0), None, None, vec![participant(0, "Alice", 10)]);
        game.status = GameStatus::Active;
        assert_eq!(finished_game_summary(&game), None);
    }

    #[test]
    fn names_the_winner_with_no_rack_bonus() {
        let game = finished_game(
            Some(1),
            None,
            None,
            vec![participant(0, "Alice", 5), participant(1, "Bob", 20)],
        );
        assert_eq!(
            finished_game_summary(&game),
            Some("Game over — Bob won!".to_string())
        );
    }

    #[test]
    fn a_tie_names_no_one() {
        let game = finished_game(
            None,
            None,
            None,
            vec![participant(0, "Alice", 10), participant(1, "Bob", 10)],
        );
        assert_eq!(
            finished_game_summary(&game),
            Some("Game over — it's a tie!".to_string())
        );
    }

    #[test]
    fn going_out_names_the_winner_and_the_rack_bonus() {
        let game = finished_game(
            Some(0),
            Some(0),
            Some(10),
            vec![participant(0, "Alice", 30), participant(1, "Bob", -10)],
        );
        assert_eq!(
            finished_game_summary(&game),
            Some(
                "Game over — Alice won! Alice went out and picked up a 10-point bonus from the other players' racks."
                    .to_string()
            )
        );
    }

    #[test]
    fn a_zero_point_bonus_is_not_worth_mentioning() {
        let game = finished_game(
            Some(0),
            Some(0),
            Some(0),
            vec![participant(0, "Alice", 30), participant(1, "Bob", 0)],
        );
        assert_eq!(
            finished_game_summary(&game),
            Some("Game over — Alice won!".to_string())
        );
    }
}
