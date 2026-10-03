//! Human-readable display labels for edition names — shared between the
//! games-list/summary rows and the custom-game builder's picker. The picker
//! only ever offers `rules_shared::VariantRules::EDITION_NAMES`, but the
//! games list also has to label *retired* editions: a game persists its own
//! copy of the rules it was created with, so it keeps playing (and keeps
//! needing a label) long after the registry stops offering that edition.

pub fn edition_label(name: &str) -> &'static str {
    match name {
        "official" => "English (International)",
        "north_american" => "English (Americas)",
        "german" => "German",
        "spanish" => "Spanish (Castilian)",
        "spicy" => "English (Spicy)",
        // Retired editions — no longer in the registry, still on old games.
        "wordfeud" => "English (retired variant)",
        _ => "Unknown edition",
    }
}

#[cfg(test)]
mod tests {
    use super::edition_label;

    #[test]
    fn every_offered_edition_has_a_label() {
        for name in rules_shared::VariantRules::EDITION_NAMES {
            assert_ne!(
                edition_label(name),
                "Unknown edition",
                "edition {name} is offered in the picker but has no display label"
            );
        }
    }

    #[test]
    fn retired_editions_still_label_for_games_created_under_them() {
        assert_eq!(edition_label("wordfeud"), "English (retired variant)");
        assert_eq!(edition_label("not-a-real-edition"), "Unknown edition");
    }
}
