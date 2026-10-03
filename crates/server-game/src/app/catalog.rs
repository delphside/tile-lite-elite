use super::*;

pub(crate) async fn health(State(state): State<AppState>) -> Json<api::HealthDto> {
    Json(api::HealthDto {
        status: "ok".to_string(),
        api_version: api::API_VERSION,
        app_version: app_version(),
        schema_version: state.schema_version,
    })
}

pub(crate) async fn list_engines(
    State(state): State<AppState>,
) -> Json<Vec<api::EngineProfileDto>> {
    Json(state.engines.metadata())
}

/// Serves a dictionary's raw word-list text on request, for clients (the
/// wasm/web build specifically) that fetch it at runtime rather than
/// embedding it at compile time — the server already has this exact text
/// compiled in (`rules_shared::sowpods_word_list`), so this is just
/// re-serving it, not a second copy of the file anywhere.
///
/// Sign-in required, unlike `/health`/`/engines`. Not because a word list
/// is sensitive — it plainly isn't, and any signed-in player can still
/// pull the whole file — but because this endpoint is the one place the
/// project *redistributes* its word lists rather than merely using them,
/// and SOWPODS is Collins-derived with no recoverable provenance (see
/// ATTRIBUTIONS.md). Serving it to authenticated players of this game is a
/// materially different act from serving it to the open internet, and the
/// only client that needs it is a signed-in player's anyway.
pub(crate) async fn get_dictionary(
    Path(name): Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<String, ApiProblem> {
    authenticated_player_id(&state, &headers)
        .await
        .ok_or_else(|| ApiProblem::unauthorized("Sign in to fetch a dictionary"))?;

    match name.as_str() {
        "sowpods" => Ok(rules_shared::sowpods_word_list().to_string()),
        "enable2k" => Ok(rules_shared::enable2k_word_list().to_string()),
        "german" => Ok(rules_shared::german_word_list().to_string()),
        "spanish" => Ok(rules_shared::spanish_word_list().to_string()),
        _ => Err(ApiProblem::not_found(format!(
            "Unknown dictionary '{name}'"
        ))),
    }
}
