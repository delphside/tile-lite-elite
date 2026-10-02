use rules_shared::{
    GameState, MoveCandidate, MoveGenerator, Rack, RulesEngine, Score, VariantRules,
    dictionary_by_name,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineCapabilities {
    pub supports_timed_play: bool,
    pub supports_analysis: bool,
    pub supports_ranking: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineMetadata {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: Option<String>,
    pub description: Option<String>,
    pub supported_variants: Vec<String>,
    pub capabilities: EngineCapabilities,
}

#[derive(Debug, Clone, Copy)]
pub struct EngineRequest<'a> {
    pub state: &'a GameState,
    pub seat_number: u8,
    pub rack: &'a Rack,
    /// The actual game's rules — an engine must score/generate moves under
    /// these, not some rules it happens to carry internally, or it would
    /// silently misplay any edition other than whatever it was built for.
    pub rules: &'a VariantRules,
    pub time_budget_ms: Option<u64>,
}

#[derive(Debug, Clone)]
pub struct EngineResponse {
    pub action: EngineAction,
    pub diagnostics: EngineDiagnostics,
}

#[derive(Debug, Clone)]
pub enum EngineAction {
    Place(MoveCandidate),
    Pass,
    Exchange(Vec<rules_shared::Tile>),
    Resign,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct EngineDiagnostics {
    pub explanation: Option<String>,
    pub candidate_count: usize,
    pub chosen_score: Option<Score>,
}

/// Does this placement form a word an engine should decline?
///
/// Checked against the validated move rather than the candidate, so it sees the
/// words as the rules actually read them — blanks resolved, cross words
/// included. Every word the placement forms is checked, not just the one the
/// engine was aiming for.
///
/// The list is handed in rather than read here so a test can state the case it
/// means — which word is declined and which is played — instead of depending on
/// whichever words the generated greylist happens to hold this month.
fn move_is_avoided_by(
    validated: &rules_shared::model::ValidatedMove,
    avoid: &dyn Fn(&str) -> bool,
) -> bool {
    avoid(&validated.preview.main_word)
        || validated
            .preview
            .cross_words
            .iter()
            .any(|cross| avoid(&cross.word))
}

pub trait GameEngine: Send + Sync {
    fn metadata(&self) -> &EngineMetadata;

    fn choose_action(&self, request: EngineRequest<'_>) -> EngineResponse;
}

#[derive(Debug, Clone)]
pub struct GreedyEngine {
    metadata: EngineMetadata,
}

impl GreedyEngine {
    pub fn new() -> Self {
        Self {
            metadata: EngineMetadata {
                id: "greedy-v1".to_string(),
                name: "Greedy".to_string(),
                version: "1".to_string(),
                author: Some("tile-lite-elite".to_string()),
                description: Some(
                    "Chooses the highest-scoring legal move from the shared move generator."
                        .to_string(),
                ),
                // The algorithm itself has no edition-specific logic — it
                // just runs the shared move generator/validator under
                // whichever `VariantRules` the request carries — so every
                // edition the server knows about is listed here explicitly
                // as a deliberate declaration, not a limitation.
                // Retired editions are included deliberately: the server
                // refuses to run an engine whose metadata omits a game's
                // variant (`game_state::maybe_run_engine_turn`), so dropping
                // a withdrawn edition from this list would strand any bot
                // still seated in a game created under it.
                supported_variants: VariantRules::EDITION_NAMES
                    .iter()
                    .chain(VariantRules::RETIRED_EDITION_NAMES)
                    .map(|name| (*name).to_string())
                    .collect(),
                capabilities: EngineCapabilities {
                    supports_timed_play: false,
                    supports_analysis: false,
                    supports_ranking: false,
                },
            },
        }
    }
}

impl Default for GreedyEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl GreedyEngine {
    /// The highest-scoring legal move the engine is willing to play, and how
    /// many candidates it looked at.
    ///
    /// The list is handed in rather than read here for the same reason
    /// `move_is_avoided_by` takes one: the selection rule below is worth testing
    /// against a list a test controls, rather than against whichever words the
    /// generated greylist happens to hold.
    fn best_move(
        request: &EngineRequest<'_>,
        avoid: &dyn Fn(&str) -> bool,
    ) -> (Option<(MoveCandidate, Score)>, usize) {
        let engine = RulesEngine {
            rules: request.rules,
            dictionary: dictionary_by_name(&request.rules.language)
                .expect("request rules should reference a known dictionary"),
        };

        let mut best: Option<(MoveCandidate, Score)> = None;
        let mut candidate_count = 0;

        for candidate in engine.enumerate_legal_moves(request.state, request.rack) {
            candidate_count += 1;
            if let Ok(validated) =
                engine.validate_game_move(request.state, Some(request.rack), &candidate)
            {
                let score = validated.score.total;
                match &best {
                    Some((_, best_score)) if *best_score >= score => {}
                    // An engine does not play a greylisted word, however well
                    // it scores. A person choosing a rude word is expressing
                    // themselves; a machine doing it reads as the game
                    // insulting you — which is why the greylist has the engine
                    // as its subject and leaves the dictionary alone.
                    //
                    // Every word the placement forms is checked, not just the
                    // main one: a cross word is as much the engine's choice as
                    // the word it was aiming for.
                    //
                    // Checked here, and not before the comparison, because a
                    // move that will not win does not matter — greedy play only
                    // ever asks about the move it is about to keep. That turns
                    // the cost from one check per legal move into one per
                    // improvement on the best so far, which is the number of
                    // running maxima in the sequence: about ln(n), so single
                    // digits where there were hundreds. The result is identical
                    // either way, because `best` is only ever replaced by a
                    // move that survives the check.
                    _ if !move_is_avoided_by(&validated, avoid) => best = Some((candidate, score)),
                    _ => {}
                }
            }
        }

        (best, candidate_count)
    }
}

impl GameEngine for GreedyEngine {
    fn metadata(&self) -> &EngineMetadata {
        &self.metadata
    }

    fn choose_action(&self, request: EngineRequest<'_>) -> EngineResponse {
        let (best, candidate_count) = Self::best_move(&request, &|word| {
            rules_shared::wordlists::is_avoided_by_engines(word)
        });

        match best {
            Some((candidate, score)) => EngineResponse {
                action: EngineAction::Place(candidate),
                diagnostics: EngineDiagnostics {
                    explanation: Some("selected best legal move by score".to_string()),
                    candidate_count,
                    chosen_score: Some(score),
                },
            },
            None => EngineResponse {
                action: EngineAction::Pass,
                diagnostics: EngineDiagnostics {
                    explanation: Some("no legal move available".to_string()),
                    candidate_count,
                    chosen_score: None,
                },
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{EngineAction, EngineRequest, GameEngine, GreedyEngine};
    use rules_shared::{GERMAN, GameState, Letter, Rack, SOWPODS, VariantRules};

    /// A word the engine should decline is declined — including when it is a
    /// cross word rather than the one being aimed for.
    ///
    /// Against an injected list, so the case is stated rather than borrowed from
    /// the generated one (see `rules-shared/src/wordlists/README.md`). This
    /// is the predicate on its own; `the_next_best_move_is_played_when_the_best_is_avoided`
    /// covers the selection that uses it.
    #[test]
    fn a_move_forming_an_avoided_word_is_declined() {
        use rules_shared::model::{
            CrossWordPreview, Direction, MoveCandidate, MovePreview, MoveScore, Position,
        };

        let preview = |main: &str, cross: &str| MovePreview {
            legal: true,
            main_word: main.to_string(),
            total_score: 0,
            cross_words: vec![CrossWordPreview {
                pos: Position { x: 0, y: 0 },
                word: cross.to_string(),
                score: 0,
            }],
            error: None,
        };
        let validated = |main: &str, cross: &str| rules_shared::model::ValidatedMove {
            candidate: MoveCandidate {
                start: Position { x: 0, y: 0 },
                direction: Direction::Horizontal,
                tiles: Vec::new(),
            },
            preview: preview(main, cross),
            score: MoveScore {
                total: 0,
                main_word_score: 0,
                cross_word_score: 0,
                bingo_bonus: 0,
            },
        };
        let avoid = |word: &str| word.eq_ignore_ascii_case("DAMN");

        assert!(
            super::move_is_avoided_by(&validated("DAMN", "AT"), &avoid),
            "the word being aimed for"
        );
        assert!(
            super::move_is_avoided_by(&validated("AT", "DAMN"), &avoid),
            "a cross word is as much the engine's choice as the main one"
        );
        assert!(
            !super::move_is_avoided_by(&validated("AT", "ON"), &avoid),
            "an ordinary move is left alone"
        );
    }

    /// The engine still plays against the real, populated greylist.
    ///
    /// Worth pinning because the failure mode of a list this size is not a
    /// wrong move, it is *no* move — a greylist wide enough to eliminate every
    /// candidate would show up as a bot that passes, which reads as the engine
    /// being broken rather than as the list being too long. This goes through
    /// the shipped list rather than an injected one for exactly that reason.
    #[test]
    fn the_engine_still_plays_against_the_real_greylist() {
        let rules = VariantRules::official();
        let state = GameState::new(&rules, &*SOWPODS);
        let engine = GreedyEngine::new();
        let mut rack = Rack::default();
        rack.add_letter(Letter::from('A'));
        rack.add_letter(Letter::from('T'));

        let response = engine.choose_action(EngineRequest {
            state: &state,
            seat_number: 0,
            rack: &rack,
            rules: &rules,
            time_budget_ms: None,
        });
        assert!(
            matches!(response.action, EngineAction::Place(_)),
            "the greylist must not leave the engine with nothing to play"
        );
    }

    /// The end-to-end case: the highest-scoring play is greylisted, so the
    /// engine takes the next best instead of playing it or giving up.
    ///
    /// Written against an injected list, which is what `best_move` takes one
    /// for. It matters more than it looks, because the check runs *after* the
    /// score comparison — only on a move about to become the new best — so a
    /// mistake in that ordering would show up here as the engine either playing
    /// the avoided word anyway or passing when a legal alternative existed.
    ///
    /// The word to avoid is discovered rather than hardcoded: whichever move
    /// wins with nothing avoided is the one then forbidden, so the test does
    /// not depend on the dictionary's contents or on how ties happen to break.
    #[test]
    fn the_next_best_move_is_played_when_the_best_is_avoided() {
        use rules_shared::RulesEngine;

        let rules = VariantRules::official();
        let state = GameState::new(&rules, &*SOWPODS);
        let mut rack = Rack::default();
        for letter in ['A', 'T', 'E', 'S', 'R'] {
            rack.add_letter(Letter::from(letter));
        }
        let request = || EngineRequest {
            state: &state,
            seat_number: 0,
            rack: &rack,
            rules: &rules,
            time_budget_ms: None,
        };

        let (best, _) = GreedyEngine::best_move(&request(), &|_| false);
        let (winner, winning_score) = best.expect("a rack of ATESR has an opening move");

        let engine = RulesEngine {
            rules: &rules,
            dictionary: &*SOWPODS,
        };
        let winning_word = engine
            .validate_game_move(&state, Some(&rack), &winner)
            .expect("the chosen move validated once already")
            .preview
            .main_word;

        let (next, _) = GreedyEngine::best_move(&request(), &|word| word == winning_word);
        let (runner_up, runner_up_score) =
            next.expect("forbidding one word must not stop the engine playing");

        let runner_up_word = engine
            .validate_game_move(&state, Some(&rack), &runner_up)
            .expect("the chosen move validated once already")
            .preview
            .main_word;

        assert_ne!(
            runner_up_word, winning_word,
            "the avoided word must not be played"
        );
        assert!(
            runner_up_score <= winning_score,
            "the next best cannot outscore the best: {runner_up_score} > {winning_score}"
        );
    }

    /// The case the whole mechanism exists for, against the **real** greylist:
    /// a position where the highest-scoring move forms a greylisted word, and
    /// the engine takes the lesser one instead.
    ///
    /// Every other test here injects its own predicate, which means none of
    /// them touches `is_avoided_by_engines` or the committed list at all. That
    /// gap could fail *open* without a single test noticing: `contains` guards
    /// its "callers pass an uppercase word" contract with a `debug_assert`,
    /// which is compiled out of release builds, so a word arriving in a form
    /// the list does not match would simply be played. An injected closure
    /// comparing two strings cannot detect that; only going through the real
    /// list can.
    ///
    /// An empty board and a rack of Z, E, X, which the dictionary allows
    /// exactly two words from: ZEX at 38, which is greylisted, and EX at 18,
    /// which is not. Two options rather than many, so the assertion is "it
    /// played the other one" rather than "it played something else".
    ///
    /// The control matters as much as the result. Without asserting that the
    /// unrestrained engine really does prefer ZEX, this test would still pass
    /// if the position stopped being one where a greylisted word wins — and
    /// would then be proving nothing while looking green.
    #[test]
    fn the_bot_declines_a_greylisted_word_that_would_have_won() {
        use rules_shared::{MoveCandidate, RulesEngine};

        let rules = VariantRules::official();
        let state = GameState::new(&rules, &*SOWPODS);
        let mut rack = Rack::default();
        for letter in ['Z', 'E', 'X'] {
            rack.add_letter(Letter::from(letter));
        }
        let request = || EngineRequest {
            state: &state,
            seat_number: 0,
            rack: &rack,
            rules: &rules,
            time_budget_ms: None,
        };
        let engine = RulesEngine {
            rules: &rules,
            dictionary: &*SOWPODS,
        };
        let word_of = |candidate: &MoveCandidate| {
            engine
                .validate_game_move(&state, Some(&rack), candidate)
                .expect("the chosen move validated once already")
                .preview
                .main_word
        };

        // Control: unrestrained, the best move forms a greylisted word.
        let (unrestrained, _) = GreedyEngine::best_move(&request(), &|_| false);
        let (best, best_score) = unrestrained.expect("ZEX is playable on an empty board");
        let best_word = word_of(&best);
        assert!(
            rules_shared::wordlists::is_avoided_by_engines(&best_word),
            "control failed: the top move here is {best_word}, which is not greylisted, \
             so this position no longer tests anything"
        );

        // The real engine, through the committed list rather than an injected one.
        let response = GreedyEngine::new().choose_action(request());
        let EngineAction::Place(played) = response.action else {
            panic!(
                "the engine passed, though EX was available: {:?}",
                response.action
            );
        };
        let played_word = word_of(&played);

        assert!(
            !rules_shared::wordlists::is_avoided_by_engines(&played_word),
            "the engine played {played_word}, which is greylisted"
        );
        assert!(
            response.diagnostics.chosen_score.unwrap() < best_score,
            "declining the best move should cost score, but it did not"
        );
    }

    #[test]
    fn greedy_engine_plays_opening_move_when_available() {
        let rules = VariantRules::official();
        let state = GameState::new(&rules, &*SOWPODS);
        let engine = GreedyEngine::new();
        let mut rack = Rack::default();
        rack.add_letter(Letter::from('A'));
        rack.add_letter(Letter::from('T'));

        let response = engine.choose_action(EngineRequest {
            state: &state,
            seat_number: 0,
            rack: &rack,
            rules: &rules,
            time_budget_ms: None,
        });

        assert!(matches!(response.action, EngineAction::Place(_)));
    }

    #[test]
    fn greedy_engine_plays_correctly_under_a_non_official_ruleset_too() {
        // Regression test: the engine used to hardcode `VariantRules::official()`
        // internally regardless of what `EngineRequest` carried, which would
        // have silently misplayed (wrong letter values/premiums) any other
        // edition. It must actually use `request.rules`.
        // German, because it is the edition furthest from official: its own
        // dictionary, its own 29-letter alphabet, and its own letter values
        // (H is 2 here, 4 in official) — so a hardcoded `official()` shows up
        // as a wrong score rather than an accidentally-identical one.
        let rules = VariantRules::german();
        let state = GameState::new(&rules, &*GERMAN);
        let engine = GreedyEngine::new();
        let mut rack = Rack::default();
        rack.add_letter(Letter::from('A'));
        rack.add_letter(Letter::from('H'));

        assert!(engine.metadata().supported_variants.contains(&rules.name));

        let response = engine.choose_action(EngineRequest {
            state: &state,
            seat_number: 0,
            rack: &rack,
            rules: &rules,
            time_budget_ms: None,
        });

        assert!(matches!(response.action, EngineAction::Place(_)));
    }
}
