use super::*;

// ========== Game Invitation Handlers ==========

/// Records that a game's invitations changed, and tells everyone watching.
///
/// **Every write to `game_invitations` must end here.** A seat's invitation
/// status is rendered as part of the game but stored in its own table, and
/// `version` — the only freshness signal a client has — lives on the
/// `GameSession`. So a row written without this leaves every open tab showing
/// the old seat: not by broadcast, since none is sent, and not by an explicit
/// refresh either, since `should_apply_update` only takes a version higher
/// than the one already held. A full page reload is the only thing that
/// notices, which is how three of these were found — by reloading.
///
/// Funnelled rather than repeated because there are seven writers across
/// three modules and nothing in the type system connects them. Some of them
/// happen to be safe already — accepting claims a seat, withdrawing releases
/// one, removing a seat removes it, and each of those bumps `version` on its
/// own account. That is luck, not design: it holds only while the invitation
/// change travels with a change to the session, and it is exactly why the two
/// that did not (sending, declining) went unnoticed until somebody reloaded a
/// page. **If in doubt, call this. Calling it twice is harmless** — `version`
/// is a counter and a second identical update is discarded by the client.
///
/// The underlying split is a data-model question rather than a coding one,
/// and is tracked as its own design note.
pub(crate) async fn announce_invitation_change(
    state: &AppState,
    game_id: &str,
) -> Result<(), ApiProblem> {
    let dto = {
        let mut games = state.games.write().await;
        let Some(game) = games.get_mut(game_id) else {
            // A game that has gone since the write is not an error worth
            // failing the caller's action over — there is simply nobody left
            // to tell.
            return Ok(());
        };
        game.touch();
        persistence::save_game(&state.db, game)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        game_dto_with_invitation_status(state, game).await?
    };
    let _ = state.events.send(GameEventDto::StateUpdated { game: dto });
    Ok(())
}

pub(crate) async fn invite_player_to_game(
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InvitePlayerRequest>,
) -> Result<Json<GameInvitationDto>, ApiProblem> {
    let inviting_player_id = authenticated_player_id(&state, &headers)
        .await
        .ok_or_else(|| ApiProblem::unauthorized("Sign in to invite players"))?;

    let games = state.games.read().await;
    let game = games
        .get(&game_id)
        .ok_or_else(|| ApiProblem::not_found("Game not found"))?;

    if game.status != api::GameStatus::Waiting {
        return Err(ApiProblem::bad_request(
            "Game must be in waiting state to invite players",
        ));
    }

    if !caller_may_manage_game(game, Some(&inviting_player_id)) {
        return Err(ApiProblem::unauthorized(
            "Only the game's creator can invite players",
        ));
    }

    let seat = game
        .participants
        .iter()
        .find(|p| p.seat_number == request.seat_number)
        .ok_or_else(|| ApiProblem::bad_request("No such seat"))?;
    if seat.kind != api::SeatKind::Human || seat.player_id.is_some() {
        return Err(ApiProblem::bad_request(
            "That seat is not open to be invited to",
        ));
    }
    if persistence::get_pending_invitation_for_seat(&state.db, &game_id, request.seat_number)
        .await
        .map_err(ApiProblem::from_sqlx)?
        .is_some()
    {
        return Err(ApiProblem::bad_request(
            "This seat already has a pending invitation",
        ));
    }

    if request.invited_display_name.is_some() && request.invited_email.is_some() {
        return Err(ApiProblem::bad_request(
            "An invitation can target a display name or an email, not both",
        ));
    }

    // `None` means an open/stranger invitation — any logged-in player may
    // accept it, not just one specific invitee.
    let invited_player = match &request.invited_display_name {
        Some(display_name) => Some(
            persistence::get_player_by_name(&state.db, display_name)
                .await
                .map_err(ApiProblem::from_sqlx)?
                .ok_or_else(|| {
                    ApiProblem::not_found(format!("No player named '{display_name}'"))
                })?,
        ),
        None => None,
    };
    let invited_email = request.invited_email.as_deref();

    let inviting_player = persistence::get_player_by_id(&state.db, &inviting_player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?
        .ok_or_else(|| ApiProblem::unauthorized("Session is invalid or has expired"))?;

    let invitation_id = Uuid::new_v4().to_string();
    let record = persistence::create_invitation(
        &state.db,
        &invitation_id,
        &game_id,
        invited_player.as_ref().map(|p| p.id.as_str()),
        &inviting_player_id,
        request.seat_number,
        invited_email,
    )
    .await
    .map_err(ApiProblem::from_sqlx)?;

    tracing::info!(
        game_id,
        invitation_id,
        seat_number = request.seat_number,
        invited_player_id = record.invited_player_id.as_deref(),
        "invitation created"
    );

    // `game`/`seat` (borrowed from this guard) aren't needed past this
    // point — released explicitly rather than held across the email send
    // below, which talks to an external service and could be much slower
    // than the local DB awaits this guard was already (pre-existing
    // pattern) held across.
    drop(games);

    announce_invitation_change(&state, &game_id).await?;

    // Named and email invitations have a specific address to notify — an
    // open/stranger invitation has no invitee yet, just an open seat.
    if let Some(invited_player) = &invited_player {
        crate::email::send_invitation(
            &state.email,
            &invited_player.email,
            &invited_player.display_name,
            &inviting_player.display_name,
            &state.public_base_url,
        )
        .await;
    } else if let Some(invited_email) = invited_email {
        let join_url = format!("{}/invite?id={}", state.public_base_url, record.id);
        crate::email::send_join_invitation(
            &state.email,
            invited_email,
            &inviting_player.display_name,
            &join_url,
        )
        .await;
    }

    Ok(Json(GameInvitationDto {
        id: record.id,
        game_id: record.game_id,
        invited_player_id: record.invited_player_id,
        inviting_player_id: record.inviting_player_id,
        seat_number: record.seat_number,
        status: InvitationStatus::Pending,
        created_at: record.created_at,
        responded_at: None,
        inviting_player_display_name: inviting_player.display_name,
    }))
}

pub(crate) async fn list_player_invitations(
    Path(player_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Vec<GameInvitationDto>>, ApiProblem> {
    let invitations = persistence::get_invitations_for_player(&state.db, &player_id)
        .await
        .map_err(|_| ApiProblem::bad_request("Database error"))?;

    let mut result = Vec::new();
    for inv in invitations {
        let inviting_player = persistence::get_player_by_id(&state.db, &inv.inviting_player_id)
            .await
            .map_err(|_| ApiProblem::bad_request("Database error"))?;

        if let Some(inviter) = inviting_player {
            result.push(GameInvitationDto {
                id: inv.id,
                game_id: inv.game_id,
                invited_player_id: inv.invited_player_id,
                inviting_player_id: inv.inviting_player_id,
                seat_number: inv.seat_number,
                status: invitation_status_from_str(&inv.status),
                created_at: inv.created_at,
                responded_at: inv.responded_at,
                inviting_player_display_name: inviter.display_name,
            });
        }
    }

    Ok(Json(result))
}

pub(crate) fn invitation_status_from_str(status: &str) -> InvitationStatus {
    match status {
        "accepted" => InvitationStatus::Accepted,
        "rejected" => InvitationStatus::Rejected,
        "cancelled" => InvitationStatus::Cancelled,
        _ => InvitationStatus::Pending,
    }
}

/// Unauthenticated: the landing page an emailed join link opens on needs
/// this before the visitor has necessarily registered or logged in — see
/// `api::InvitationPreviewDto`'s doc comment for exactly what it does and
/// doesn't reveal.
pub(crate) async fn preview_invitation(
    Path(invitation_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<api::InvitationPreviewDto>, ApiProblem> {
    let invitation = persistence::get_invitation_by_id(&state.db, &invitation_id)
        .await
        .map_err(ApiProblem::from_sqlx)?
        .ok_or_else(|| ApiProblem::not_found("Invitation not found"))?;
    let inviter = persistence::get_player_by_id(&state.db, &invitation.inviting_player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?
        .ok_or_else(|| ApiProblem::not_found("Invitation not found"))?;

    Ok(Json(api::InvitationPreviewDto {
        inviting_player_display_name: inviter.display_name,
        status: invitation_status_from_str(&invitation.status),
    }))
}

pub(crate) async fn accept_invitation(
    Path(invitation_id): Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<api::GameStateDto>, ApiProblem> {
    let caller_player_id = authenticated_player_id(&state, &headers)
        .await
        .ok_or_else(|| ApiProblem::unauthorized("Sign in to accept an invitation"))?;

    // Race-safe: for an open invitation, this is where "first to accept
    // wins" is actually decided (an atomic DB update, not a check-then-act
    // in application code) — see `claim_invitation`.
    let record = persistence::claim_invitation(&state.db, &invitation_id, &caller_player_id)
        .await
        .map_err(|error| match error {
            persistence::ClaimInvitationError::NotFound => {
                ApiProblem::not_found("Invitation not found")
            }
            persistence::ClaimInvitationError::NoLongerAvailable => ApiProblem::bad_request(
                "This invitation is no longer available — it may already have been claimed",
            ),
            persistence::ClaimInvitationError::NotYourInvitation => {
                ApiProblem::unauthorized("This invitation was not sent to you")
            }
        })?;

    // Needed to fill in the seat's real display name below — an Open
    // seat's participant row is created with a generic "Open seat"
    // placeholder (there's no invitee to name yet), and a Named seat's
    // already-correct name shouldn't silently diverge from the account
    // that actually claimed it (e.g. after a display-name change).
    let claimant = persistence::get_player_by_id(&state.db, &caller_player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?
        .ok_or_else(|| ApiProblem::unauthorized("Session is invalid or has expired"))?;

    let (mut dto, access) = {
        let mut games = state.games.write().await;
        let game = games
            .get_mut(&record.game_id)
            .ok_or_else(|| ApiProblem::not_found("Game not found"))?;
        // Through the method, not inline: `claim_seat` bumps `version`, and
        // without that the state change reaches no client at all — not by
        // broadcast, and not by an explicit Refresh either.
        game.claim_seat(
            record.seat_number,
            caller_player_id.clone(),
            claimant.display_name.clone(),
        );
        let dto = game.to_dto();
        persistence::save_game(&state.db, game)
            .await
            .map_err(ApiProblem::from_sqlx)?;
        let access = resolve_viewer_access(game, Some(&caller_player_id));
        (dto, access)
    };
    stats::attach_current_ratings(&state.db, &mut dto)
        .await
        .map_err(ApiProblem::from_sqlx)?;

    tracing::info!(
        invitation_id,
        game_id = %record.game_id,
        seat_number = record.seat_number,
        player_id = %caller_player_id,
        "invitation accepted; seat claimed"
    );

    // Broadcast the unredacted dto — per-connection redaction happens in
    // `stream_events`, not here (see the identical note in `start_game`).
    let _ = state
        .events
        .send(GameEventDto::StateUpdated { game: dto.clone() });
    Ok(Json(redact_game_state(dto, &access)))
}

pub(crate) async fn reject_invitation(
    Path(invitation_id): Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiProblem> {
    let caller_player_id = authenticated_player_id(&state, &headers)
        .await
        .ok_or_else(|| ApiProblem::unauthorized("Sign in to reject an invitation"))?;

    let invitations = persistence::get_invitations_for_player(&state.db, &caller_player_id)
        .await
        .map_err(ApiProblem::from_sqlx)?;
    let invitation = invitations
        .iter()
        .find(|inv| inv.id == invitation_id)
        .ok_or_else(|| {
            // Either it doesn't exist, or it's an open invitation with no
            // single invitee — either way, there's nothing for this caller
            // to reject.
            ApiProblem::not_found("Invitation not found")
        })?;
    if invitation.status != "pending" {
        return Err(ApiProblem::bad_request(
            "This invitation has already been responded to",
        ));
    }

    persistence::update_invitation_status(&state.db, &invitation_id, "rejected")
        .await
        .map_err(ApiProblem::from_sqlx)?;

    announce_invitation_change(&state, &invitation.game_id).await?;

    tracing::info!(invitation_id, player_id = %caller_player_id, "invitation rejected");

    Ok(Json(serde_json::json!({
        "status": "rejected"
    })))
}
