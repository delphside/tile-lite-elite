use super::*;

/// The daily record of what the database holds (#90).
///
/// Read here rather than anywhere public: it is production data, and this is
/// where production questions are already asked. No thresholds and no
/// comparison — those are #89, and they need this to have been running a while
/// before they can be written honestly.
pub(crate) async fn admin_list_database_size(
    State(state): State<AppState>,
) -> Result<Json<Vec<api::AdminDatabaseSizeDto>>, ApiProblem> {
    let rows = persistence::list_database_size_history(&state.db, 90)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    Ok(Json(
        rows.into_iter()
            .map(|r| api::AdminDatabaseSizeDto {
                recorded_on: r.recorded_on,
                recorded_at: r.recorded_at,
                players: r.players,
                sessions: r.sessions,
                games: r.games,
                invitations: r.invitations,
                chat_messages: r.chat_messages,
                database_bytes: r.database_bytes,
                games_in_memory: r.games_in_memory,
            })
            .collect(),
    ))
}

pub(crate) async fn require_loopback(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    request: Request,
    next: Next,
) -> Response {
    if !addr.ip().is_loopback() {
        return ApiProblem::forbidden("Admin endpoints are only reachable from the server itself")
            .into_response();
    }
    next.run(request).await
}

// Reachable only from loopback (see `require_loopback`) — an operator with
// terminal access to the server, not player-facing, hence no per-account
// auth here.

pub(crate) async fn admin_list_users(
    State(state): State<AppState>,
) -> Result<Json<Vec<api::AdminPlayerSummaryDto>>, ApiProblem> {
    let players = persistence::list_player_summaries(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    Ok(Json(players))
}

pub(crate) async fn admin_delete_user(
    State(state): State<AppState>,
    Path(player_id): Path<String>,
) -> Result<StatusCode, ApiProblem> {
    // Refuse while anything still refers to the account — a game it created,
    // a seat it holds, or an invitation it has not answered
    // (docs/1.0-rules.md, DEL-2).
    //
    // Deleting a user with games attached is what raises every awkward
    // question: unclaimed seats, an unmanageable game whose creator is gone,
    // another player's history half-owned by an account that no longer
    // exists. Requiring the references to be gone first removes all of them.
    //
    // It is only reasonable because references expire on their own: a
    // completed game is swept a week after it ends and takes its invitations
    // with it, and an unstarted one runs a 30-day countdown unless its creator
    // keeps answering to keep it — which a departing user will not. So the
    // admin waits, or deletes the games explicitly first. Two ordered commands
    // rather than one with cascading semantics.
    {
        let mentioned_by = persistence::game_ids_mentioning_player(&state.db, &player_id)
            .await
            .map_err(ApiProblem::from_sqlx)?;

        let games = state.games.read().await;
        let attached: Vec<&GameSession> = games
            .values()
            .filter(|game| {
                game.creator_player_id.as_deref() == Some(player_id.as_str())
                    || game
                        .participants
                        .iter()
                        .any(|seat| seat.player_id.as_deref() == Some(player_id.as_str()))
            })
            .collect();
        // One row per game, whatever number of ways it refers to the account.
        // A creator who invited somebody is both attached and mentioned, and
        // listing their own game twice would read as two problems.
        let mentioned: Vec<&GameSession> = mentioned_by
            .iter()
            .filter(|game_id| !attached.iter().any(|game| &&game.id == game_id))
            .filter_map(|game_id| games.get(game_id))
            .collect();

        // Sent as data rather than written into the message. Whoever reads
        // this is deciding whether to wait or to act, and that decision wants
        // the same table they have just seen from `games list` — which the
        // client is far better placed to draw than the server is.
        let created_at = persistence::created_at_by_game(&state.db)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        let last_activity = persistence::last_activity_by_game(&state.db)
            .await
            .map_err(ApiProblem::from_sqlx)?;

        let mut blocking: Vec<api::AdminGameSummaryDto> = Vec::new();
        for game in attached.iter().chain(mentioned.iter()) {
            // Each seat's invitation status comes from the invitations table,
            // not the session, so it has to be filled in — without it every
            // empty seat reads "unclaimed", and a seat somebody turned down
            // looks like one nobody was ever asked about.
            let mut dto = game.to_dto();
            let invitations = persistence::get_invitations_for_game(&state.db, &game.id)
                .await
                .map_err(ApiProblem::from_sqlx)?;
            crate::game_state::attach_invitation_status(&mut dto.participants, &invitations);
            blocking.push(api::AdminGameSummaryDto {
                id: game.id.clone(),
                status: game.status,
                created_at: created_at.get(&game.id).copied().unwrap_or(0),
                last_activity_at: last_activity.get(&game.id).copied().unwrap_or(0),
                participants: dto.participants,
            });
        }

        if !blocking.is_empty() {
            // No counts and no agreement. The list below may hold one game or
            // a dozen, in any mix of states, and a sentence that tries to
            // describe them ends up either wrong or written three ways — while
            // the rows say all of it already, including why each one counts:
            // the account is visible in the seats.
            return Err(ApiProblem::blocked_by_games(
                "That account cannot be deleted yet. The games below still refer to \
                 it. Please wait until they are gone, then delete the account. Games \
                 are removed automatically from a week after their last activity, and \
                 an invitation goes with the game holding it.",
                blocking,
            ));
        }
    }

    // Somebody interested enough to be signed in is likely to play a game, and
    // a game is exactly what the guard above protects. So this is that same
    // argument one step earlier: waiting costs nothing, because the tool exists
    // to clear out *old* data and a live session is the clearest evidence that
    // this is not old data.
    //
    // Said separately from the games refusal because the remedies differ. An
    // account blocked by games waits for retention; one blocked by a session
    // waits for the session, which ACC-1 bounds at 48 hours idle and 10 days
    // absolute. Telling somebody to wait without saying what for is how a tool
    // gets a reputation for being obstructive.
    if persistence::has_live_session(&state.db, &player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?
    {
        return Err(ApiProblem::bad_request(
            "That account is signed in somewhere. Deleting it now would take an \
             account that is in use, and one that is about to create the very \
             games this command refuses to orphan. Sessions end on their own: \
             48 hours after they were last used, and 10 days at the outside.",
        ));
    }

    let deleted = persistence::delete_player(&state.db, &player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !deleted {
        return Err(ApiProblem::not_found("Player not found"));
    }

    // `delete_player` nulls `game_participants.player_id` in the database, but
    // every loaded `GameSession` is a separate in-memory copy — and the
    // creator id lives in `snapshot_json` rather than a column, so SQL cannot
    // reach it at all. `release_player` does both, bumps the version so
    // clients actually see the seat become unclaimed, and reports whether
    // anything changed so only affected games are written and announced.
    let mut touched = Vec::new();
    {
        let mut games = state.games.write().await;
        for game in games.values_mut() {
            if game.release_player(&player_id) {
                if let Err(error) = persistence::save_game(&state.db, game).await {
                    tracing::error!(game_id = %game.id, %error, "failed to persist user deletion");
                }
                touched.push(game.to_dto());
            }
        }
    }
    for dto in touched {
        let _ = state
            .events
            .send(api::GameEventDto::StateUpdated { game: dto });
    }

    tracing::warn!(player_id, "admin: user deleted");
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn admin_reset_password(
    State(state): State<AppState>,
    Path(player_id): Path<String>,
    Json(request): Json<AdminResetPasswordRequest>,
) -> Result<StatusCode, ApiProblem> {
    if request.new_password.is_empty() {
        return Err(ApiProblem::bad_request("A new password is required"));
    }
    // Bounded like every other hash, though this endpoint is loopback-only
    // with a single client: the work costs the same 19 MiB either way, and an
    // admin reset landing during a login flurry should queue with them rather
    // than adding to the total.
    let password_hash = hash_password_bounded(&state, &request.new_password).await?;
    let updated = persistence::update_player_password(&state.db, &player_id, &password_hash)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !updated {
        return Err(ApiProblem::not_found("Player not found"));
    }
    tracing::warn!(player_id, "admin: password reset");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(serde::Deserialize)]
pub(crate) struct AdminGamesQuery {
    status: Option<String>,
    older_than_days: Option<i64>,
}

pub(crate) async fn admin_list_games(
    State(state): State<AppState>,
    Query(query): Query<AdminGamesQuery>,
) -> Result<Json<Vec<AdminGameSummaryDto>>, ApiProblem> {
    let created_at = persistence::created_at_by_game(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    let last_activity = persistence::last_activity_by_game(&state.db)
        .await
        .map_err(ApiProblem::from_sqlx)?;

    let status_filter = match query.status.as_deref() {
        Some("waiting") => Some(api::GameStatus::Waiting),
        Some("active") => Some(api::GameStatus::Active),
        Some("finished") => Some(api::GameStatus::Finished),
        Some("aborted") => Some(api::GameStatus::Aborted),
        Some(other) => {
            return Err(ApiProblem::bad_request(format!(
                "Unknown status '{other}', expected waiting/active/finished/aborted"
            )));
        }
        None => None,
    };
    let cutoff = query
        .older_than_days
        .map(|days| now_unix_seconds() - days * 86_400);

    let games = state.games.read().await;
    let mut summaries: Vec<AdminGameSummaryDto> = games
        .values()
        .filter(|game| {
            status_filter
                .as_ref()
                .is_none_or(|status| &game.status == status)
        })
        .filter(|game| {
            let Some(cutoff) = cutoff else {
                return true;
            };
            created_at
                .get(&game.id)
                .is_some_and(|created| *created <= cutoff)
        })
        .map(|game| AdminGameSummaryDto {
            id: game.id.clone(),
            status: game.status,
            created_at: created_at.get(&game.id).copied().unwrap_or(0),
            last_activity_at: last_activity.get(&game.id).copied().unwrap_or(0),
            participants: game
                .participants
                .iter()
                .map(|participant| api::ParticipantDto {
                    seat_number: participant.seat_number,
                    kind: participant.kind.clone(),
                    display_name: participant.display_name.clone(),
                    player_id: participant.player_id.clone(),
                    engine_id: participant.engine_id.clone(),
                    score: participant.score,
                    // Filled in below, per game.
                    invitation_status: None,
                    invited_email: participant.invited_email.clone(),
                    rating_before: None,
                    rating_after: None,
                    current_rating: None,
                    resigned: participant.resigned,
                })
                .collect(),
        })
        .collect();
    // Each seat's invitation status lives in its own table, so it has to be
    // filled in per game. Left out while this column showed names only; now
    // that an empty seat says which kind of empty it is, leaving it out made
    // a declined seat look like one nobody had been asked about.
    for summary in &mut summaries {
        let invitations = persistence::get_invitations_for_game(&state.db, &summary.id)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        crate::game_state::attach_invitation_status(&mut summary.participants, &invitations);
    }
    summaries.sort_by_key(|s| std::cmp::Reverse(s.created_at));

    Ok(Json(summaries))
}

pub(crate) async fn admin_delete_game(
    State(state): State<AppState>,
    Path(game_id): Path<String>,
) -> Result<StatusCode, ApiProblem> {
    let deleted = persistence::delete_game(&state.db, &game_id)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    if !deleted {
        return Err(ApiProblem::not_found("Game not found"));
    }
    state.games.write().await.remove(&game_id);
    tracing::warn!(game_id, "admin: game deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// Directly marks a game `Finished` without going through per-seat
/// resignation — for an operator to clear out a stuck or abandoned game
/// (e.g. a human seat that will never act again). Doesn't touch scores or
/// `winner_seat`. Rejects a game that has already ended (see
/// `GameSession::admin_force_finish`) rather than overwriting its result.
pub(crate) async fn admin_force_end_game(
    State(state): State<AppState>,
    Path(game_id): Path<String>,
) -> Result<Json<api::GameStateDto>, ApiProblem> {
    let mut dto = {
        let mut games = state.games.write().await;
        let game = games
            .get_mut(&game_id)
            .ok_or_else(|| ApiProblem::not_found("Game not found"))?;
        game.admin_force_finish().map_err(ApiProblem::bad_request)?;
        let dto = game.to_dto();
        persistence::save_game(&state.db, game)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        dto
    };
    stats::attach_current_ratings(&state.db, &mut dto)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    // Always a no-op in practice — an admin force-end never moves rating
    // (see `stats::settle_ratings`) — but calling it anyway keeps this
    // handler consistent with every other place a Finished game's DTO
    // goes out, rather than being a special case someone has to remember.
    stats::attach_rating_deltas(&state.db, &mut dto)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    tracing::warn!(game_id, "admin: game force-ended");
    let _ = state
        .events
        .send(GameEventDto::GameFinished { game: dto.clone() });
    Ok(Json(dto))
}
