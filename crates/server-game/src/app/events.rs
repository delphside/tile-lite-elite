use super::*;

#[derive(Debug, serde::Deserialize)]
pub(crate) struct EventsQuery {
    token: Option<String>,
}

/// Browsers' native `WebSocket` API can't set custom headers on the
/// handshake, so unlike every other endpoint the session token travels as
/// a query parameter here instead of `Authorization: Bearer` — see
/// `player_id_for_token`. Previously this endpoint had no auth check at
/// all: anyone who knew or guessed a `game_id`, logged in or not, could
/// connect and receive that game's full state, including every seat's
/// rack. Now it's gated by the same `resolve_viewer_access` rule as every
/// other game-state endpoint, and `stream_events` redacts each outgoing
/// event to this specific connection's resolved tier.
pub(crate) async fn game_events(
    Path(game_id): Path<String>,
    State(state): State<AppState>,
    Query(query): Query<EventsQuery>,
    websocket: WebSocketUpgrade,
) -> Result<Response, ApiProblem> {
    let had_token = query.token.is_some();
    let player_id = match query.token {
        Some(token) => player_id_for_token(&state, &token).await,
        None => None,
    };

    let access = {
        let games = state.games.read().await;
        let Some(game) = games.get(&game_id) else {
            return Err(ApiProblem::new(Reason::GameNotFound, "Game not found"));
        };
        resolve_viewer_access(game, player_id.as_deref())
    };
    if access == ViewerAccess::Rejected {
        // Split as the HTTP routes split it: 401 for no valid credential, 403
        // for a signed-in caller who is not in the game. A browser cannot read
        // a refused handshake's status, so the client treats both as a failed
        // connection.
        return Err(match (player_id, had_token) {
            (Some(_), _) => ApiProblem::new(Reason::NotInGame, "You are not part of this game"),
            (None, true) => {
                ApiProblem::new(Reason::SessionExpired, "Session is invalid or has expired")
            }
            (None, false) => {
                ApiProblem::new(Reason::SignInRequired, "Sign in to watch this game live")
            }
        });
    }

    let events = state.events.subscribe();
    let deleted = state.deleted_games.subscribe();
    let shutdown = state.shutdown.subscribe();
    Ok(websocket.on_upgrade(move |socket| {
        stream_events(socket, game_id, access, events, deleted, shutdown)
    }))
}

/// Closes the socket with `code`: **4000 plus the HTTP status the failure
/// stands for** (docs/1.10 *Rules for every system*), or 1001 for the
/// server going away. The peer may already have gone, so the send is
/// best-effort.
async fn close_with(socket: &mut WebSocket, code: u16) {
    let _ = socket
        .send(Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: "".into(),
        })))
        .await;
}

/// Close code for a failure of the server's own while sending.
pub(crate) const CLOSE_SERVER_ERROR: u16 = 4500;
/// Close code for a game deleted under the socket, as a read of it answers 404.
pub(crate) const CLOSE_GAME_DELETED: u16 = 4404;
/// Close code for the server stopping.
pub(crate) const CLOSE_GOING_AWAY: u16 = 1001;

/// `state.events` is a single broadcast channel shared by every game on the
/// server, not one per game — every subscriber sees every game's events
/// unless it filters, which this previously didn't do at all (the path's
/// `game_id` was captured but never used). That meant a socket opened for
/// one game silently received full state for every other game in progress
/// too. The client already discarded non-matching events, so this was
/// invisible in normal play, but the leak was real on the wire.
pub(crate) fn event_belongs_to_game(event: &GameEventDto, game_id: &str) -> bool {
    let game = match event {
        GameEventDto::StateUpdated { game }
        | GameEventDto::GameStarted { game }
        | GameEventDto::GameFinished { game } => game,
    };
    game.id == game_id
}

/// Redacts an event's embedded `GameStateDto` to `access`'s tier before
/// forwarding it to this specific connection. The broadcast itself always
/// carries the full, unredacted state (every HTTP handler broadcasts that
/// way too — see the "broadcast the unredacted dto" notes throughout this
/// file); redaction only ever happens at the point data actually leaves the
/// server to a specific caller, which for a WebSocket is here, per message,
/// not once at connection time.
pub(crate) fn redact_event(event: GameEventDto, access: &ViewerAccess) -> GameEventDto {
    match event {
        GameEventDto::StateUpdated { game } => GameEventDto::StateUpdated {
            game: redact_game_state(game, access),
        },
        GameEventDto::GameStarted { game } => GameEventDto::GameStarted {
            game: redact_game_state(game, access),
        },
        GameEventDto::GameFinished { game } => GameEventDto::GameFinished {
            game: redact_game_state(game, access),
        },
    }
}

pub(crate) async fn stream_events(
    mut socket: WebSocket,
    game_id: String,
    access: ViewerAccess,
    mut rx: broadcast::Receiver<GameEventDto>,
    mut deleted: broadcast::Receiver<String>,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) {
    loop {
        let event = tokio::select! {
            _ = shutdown.changed() => {
                close_with(&mut socket, CLOSE_GOING_AWAY).await;
                return;
            }
            removed = deleted.recv() => {
                match removed {
                    Ok(id) if id == game_id => {
                        close_with(&mut socket, CLOSE_GAME_DELETED).await;
                        return;
                    }
                    // Another game's, or this receiver fell behind: keep
                    // listening; a game that is gone stays gone.
                    _ => continue,
                }
            }
            received = rx.recv() => match received {
                Ok(event) => event,
                // The sender is gone: every `AppState` has been dropped, so
                // the server is stopping.
                Err(broadcast::error::RecvError::Closed) => {
                    close_with(&mut socket, CLOSE_GOING_AWAY).await;
                    return;
                }
                // This socket fell behind the broadcast and missed events: a
                // failure of the server's, which the client answers by
                // reconnecting for the current state.
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    tracing::warn!(game_id, "a WebSocket fell behind the broadcast; closing it");
                    close_with(&mut socket, CLOSE_SERVER_ERROR).await;
                    return;
                }
            },
        };
        if !event_belongs_to_game(&event, &game_id) {
            continue;
        }
        let event = redact_event(event, &access);

        let message = match serde_json::to_string(&event) {
            Ok(message) => message,
            Err(error) => {
                tracing::error!(game_id, %error, "a game event did not serialise; closing the socket");
                close_with(&mut socket, CLOSE_SERVER_ERROR).await;
                return;
            }
        };

        // A failed send is the peer's: it has gone, and there is nobody to tell.
        if socket.send(Message::Text(message.into())).await.is_err() {
            return;
        }
    }
}
