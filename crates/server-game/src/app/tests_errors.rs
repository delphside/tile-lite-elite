//! The error scheme: every refusal is a classified `Reason`, answers RFC 9457
//! Problem Details, carries the request's ID and writes one log line (#606).
//!
//! The conditions come from programme docs/1.10 *Errors: one scheme for every
//! system*, the design, and `docs/4.4.3`, never from the code under test.

use super::*;
use crate::app::tests::{
    create_test_state, create_two_human_game, create_two_human_game_waiting, register_player,
    send_admin, start_capturing_log_on_this_thread, test_database_url,
};
use api::{
    CreateGameRequest, CreateSeatRequest, ErrorType, GameStateDto, InvitePlayerRequest,
    PostChatMessageRequest, SeatClaim, SeatKind, SwapSeatsRequest,
};
use axum::body::{Body, to_bytes};
use axum::http::{Method, Request};
use serde_json::{Value, json};
use tower::util::ServiceExt;

/// A response read once: its status, headers and body, parsed where it parses.
struct Reply {
    status: StatusCode,
    headers: HeaderMap,
    text: String,
}

impl Reply {
    fn json(&self) -> Value {
        serde_json::from_str(&self.text)
            .unwrap_or_else(|error| panic!("not JSON ({error}): {}", self.text))
    }

    fn request_id(&self) -> String {
        self.headers
            .get("x-request-id")
            .expect("every response carries x-request-id")
            .to_str()
            .unwrap()
            .to_string()
    }

    fn content_type(&self) -> &str {
        self.headers
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
    }
}

async fn call(
    app: &Router,
    method: Method,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Reply {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    let request = match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string())),
        None => builder.body(Body::empty()),
    }
    .expect("request should build");
    read(
        app.clone()
            .oneshot(request)
            .await
            .expect("the router answers"),
    )
    .await
}

async fn read(response: axum::http::Response<Body>) -> Reply {
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("body reads");
    Reply {
        status,
        headers,
        text: String::from_utf8_lossy(&bytes).into_owned(),
    }
}

async fn fresh_app() -> (Router, AppState) {
    let state = create_test_state(&test_database_url()).await;
    (build_router(state.clone()), state)
}

fn code(reason: Reason) -> String {
    serde_json::to_value(reason)
        .unwrap()
        .as_str()
        .unwrap()
        .to_string()
}

/// The status each reason answers, written out here from docs/4.4.3 rather
/// than read from `Reason::status`, so a wrong classification fails a test
/// instead of being agreed with by it.
fn pinned_status(reason: Reason) -> u16 {
    match reason {
        Reason::SignInRequired | Reason::SessionExpired => 401,
        Reason::NotGameCreator
        | Reason::NotYourSeat
        | Reason::NotSeated
        | Reason::NotInGame
        | Reason::NotYourInvitation
        | Reason::NotYourInvitations
        | Reason::AdminLoopbackOnly => 403,
        Reason::GameNotFound
        | Reason::PlayerNotFound
        | Reason::InvitationNotFound
        | Reason::DictionaryNotFound
        | Reason::NoSuchRoute => 404,
        Reason::MethodNotAllowed => 405,
        Reason::BodyTooLarge => 413,
        Reason::UnsupportedMediaType => 415,
        Reason::InvalidBody => 422,
        Reason::TooManyRequests => 429,
        Reason::Internal | Reason::EngineFailed | Reason::Unknown => 500,
        Reason::ServiceBusy => 503,
        _ => 400,
    }
}

/// T3's body conditions, for any error from anywhere.
fn assert_problem(reply: &Reply, reason: Reason) -> Value {
    assert_eq!(
        reply.content_type(),
        "application/problem+json",
        "{}: {}",
        reply.status,
        reply.text
    );
    let body = reply.json();
    let status = pinned_status(reason);
    assert_eq!(
        reason.status(),
        status,
        "{reason:?}: the enum and 4.4.3 agree"
    );
    assert_eq!(reply.status.as_u16(), status, "{}", reply.text);
    assert_eq!(body["status"], status);
    assert_eq!(body["reason"], code(reason), "{}", reply.text);
    assert_eq!(
        body["error_type"],
        serde_json::to_value(reason.error_type()).unwrap()
    );
    assert_eq!(body["blip"], reason.blip(), "blip is always present");
    assert_eq!(
        body["title"],
        reply
            .status
            .canonical_reason()
            .expect("a registered status")
    );
    assert_eq!(body["outcome"], "fatal");
    assert_eq!(body["domain"], "tile-lite-elite");
    assert!(body.get("type").is_none(), "RFC 9457 `type` is left out");
    assert!(body.get("cause").is_none(), "cause is never sent");
    assert!(body.get("errors").is_none(), "errors is never sent");
    assert!(
        !body["detail"].as_str().unwrap().is_empty(),
        "a detail sentence"
    );
    assert_eq!(
        body["message"], body["detail"],
        "message is kept beside detail"
    );
    assert_eq!(
        body["correlation_id"].as_str().unwrap(),
        reply.request_id(),
        "the body carries the request's ID"
    );
    body
}

fn crockford(id: &str) -> bool {
    id.len() == 12
        && id
            .chars()
            .all(|c| "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains(c))
}

fn seat(kind: SeatKind, name: &str, claim: Option<SeatClaim>) -> CreateSeatRequest {
    CreateSeatRequest {
        kind,
        display_name: name.to_string(),
        engine_id: None,
        claim,
    }
}

fn game_request(seats: Vec<CreateSeatRequest>, limit: Option<u64>) -> Value {
    serde_json::to_value(CreateGameRequest {
        seats,
        seed: Some(7),
        variant: None,
        language: None,
        board_layout: None,
        move_time_limit_seconds: limit,
    })
    .unwrap()
}

async fn register(app: &Router, name: &str) -> api::PlayerSessionDto {
    register_player(app.clone(), name).await
}

// --- T3, T6: every refusal is a problem, and says nothing it should not ---------

/// One request per kind of refusal the routes make, each checked against the
/// body conditions of T3, and every body against T6's word list.
#[tokio::test]
async fn every_refusal_is_a_classified_problem_and_leaks_no_words() {
    let (app, _state) = fresh_app().await;
    let game = create_two_human_game_waiting(app.clone()).await;
    let (alice, bob) = (&game.alice.session_token, &game.bob.session_token);
    let carol = register(&app, "Carol").await.session_token;
    let gid = &game.game.id;

    type Case<'a> = (Method, String, Option<&'a str>, Option<Value>, Reason);
    let too_long = "x".repeat(api_chat_limit() + 1);
    let cases: Vec<Case<'_>> = vec![
        (
            Method::GET,
            format!("/games/{gid}"),
            None,
            None,
            Reason::SignInRequired,
        ),
        (
            Method::GET,
            "/games".into(),
            None,
            None,
            Reason::SignInRequired,
        ),
        (
            Method::GET,
            "/games".into(),
            Some("no-such-token"),
            None,
            Reason::SessionExpired,
        ),
        (
            Method::POST,
            "/auth/login".into(),
            None,
            Some(json!({"display_name":"Alice","password":"wrong","stay_logged_in":false})),
            Reason::SignInFailed,
        ),
        (
            Method::POST,
            "/auth/register".into(),
            None,
            Some(
                json!({"display_name":"Alice","email":"a@example.com","password":"pw","stay_logged_in":false}),
            ),
            Reason::DisplayNameTaken,
        ),
        (
            Method::POST,
            "/auth/register".into(),
            None,
            Some(json!({"display_name":"","email":"","password":"","stay_logged_in":false})),
            Reason::RegistrationIncomplete,
        ),
        (
            Method::GET,
            "/games/nope".into(),
            Some(bob),
            None,
            Reason::GameNotFound,
        ),
        (
            Method::POST,
            format!("/games/{gid}/reorder-seats"),
            Some(bob),
            Some(
                serde_json::to_value(SwapSeatsRequest {
                    seat_a: 0,
                    seat_b: 1,
                })
                .unwrap(),
            ),
            Reason::NotGameCreator,
        ),
        (
            Method::POST,
            format!("/games/{gid}/seats/0/withdraw"),
            Some(bob),
            None,
            Reason::NotYourSeat,
        ),
        (
            Method::GET,
            format!("/games/{gid}"),
            Some(&carol),
            None,
            Reason::NotInGame,
        ),
        (
            Method::POST,
            format!("/games/{gid}/chat"),
            Some(bob),
            Some(serde_json::to_value(PostChatMessageRequest { body: "   ".into() }).unwrap()),
            Reason::ChatEmpty,
        ),
        (
            Method::POST,
            format!("/games/{gid}/chat"),
            Some(bob),
            Some(serde_json::to_value(PostChatMessageRequest { body: too_long }).unwrap()),
            Reason::ChatTooLong,
        ),
        (
            Method::POST,
            "/games".into(),
            Some(alice),
            Some(game_request(
                vec![seat(SeatKind::Human, "A", Some(SeatClaim::Creator))],
                None,
            )),
            Reason::TooFewSeats,
        ),
        (
            Method::POST,
            "/games".into(),
            Some(alice),
            Some(game_request(
                vec![
                    seat(SeatKind::Human, "A", Some(SeatClaim::Creator)),
                    seat(SeatKind::Human, "B", Some(SeatClaim::Open)),
                ],
                Some(5),
            )),
            Reason::MoveTimeLimitOutOfRange,
        ),
        (
            Method::GET,
            "/dictionaries/klingon".into(),
            Some(alice),
            None,
            Reason::DictionaryNotFound,
        ),
        (
            Method::GET,
            "/invitations/nope/preview".into(),
            None,
            None,
            Reason::InvitationNotFound,
        ),
        (
            Method::POST,
            format!("/games/{gid}/start"),
            Some(bob),
            Some(json!({})),
            Reason::NotGameCreator,
        ),
    ];

    let words = [
        "UNIQUE constraint",
        "no such table",
        "no such column",
        "NOT NULL constraint",
        "syntax error",
        "error returned from database",
        "sqlx",
        "serde",
        "Failed to deserialize",
        "missing field",
        "expected value",
        "Argon2",
        "argon2",
        "password hashing failed",
        "rate limiting failed",
        "panicked",
        "tower_governor",
        "hyper",
        "axum",
    ];
    let mut seen_ids = std::collections::HashSet::new();
    for (method, uri, token, body, reason) in cases {
        let reply = call(&app, method.clone(), &uri, token, body).await;
        let problem = assert_problem(&reply, reason);
        for word in words {
            assert!(
                !reply.text.contains(word),
                "{method} {uri}: the body carries {word:?}: {}",
                reply.text
            );
        }
        assert!(crockford(&reply.request_id()), "{}", reply.request_id());
        assert!(
            seen_ids.insert(reply.request_id()),
            "two requests shared an ID"
        );
        if reason == Reason::ChatTooLong {
            let violation = &problem["violations"][0];
            assert_eq!(violation["field"], "body");
            assert_eq!(violation["limit"], api_chat_limit());
            assert_eq!(violation["value"], api_chat_limit() + 1);
            assert_eq!(violation["reason"], "CHAT_TOO_LONG");
        }
    }

    // And the same game, asked for by one who may see it, is no problem.
    let ok = call(
        &app,
        Method::GET,
        &format!("/games/{gid}"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
    assert!(
        !ok.content_type().contains("problem"),
        "{}",
        ok.content_type()
    );
    assert!(ok.json().get("reason").is_none(), "{}", ok.text);
    assert!(crockford(&ok.request_id()), "a success carries an ID too");
}

fn api_chat_limit() -> usize {
    crate::game_state::MAX_CHAT_MESSAGE_LEN
}

/// The delete-user refusal still carries `blocking_games` beside the new members.
#[tokio::test]
async fn the_delete_user_refusal_keeps_its_blocking_games() {
    let (app, _state) = fresh_app().await;
    let game = create_two_human_game_waiting(app.clone()).await;
    let listing = read(
        send_admin::<()>(
            app.clone(),
            Method::GET,
            "/admin/users",
            crate::app::tests::loopback_peer(),
            None,
        )
        .await,
    )
    .await;
    let players: Vec<api::AdminPlayerSummaryDto> = serde_json::from_str(&listing.text).unwrap();
    let alice_id = players
        .into_iter()
        .find(|player| player.display_name == "Alice")
        .unwrap()
        .id;
    let reply = read(
        send_admin::<()>(
            app.clone(),
            Method::DELETE,
            &format!("/admin/users/{alice_id}"),
            crate::app::tests::loopback_peer(),
            None,
        )
        .await,
    )
    .await;
    let body = assert_problem(&reply, Reason::AccountHasGames);
    assert_eq!(body["blocking_games"][0]["id"], game.game.id);
}

#[tokio::test]
async fn a_refusal_from_outside_loopback_answers_the_admin_reason() {
    let (app, _state) = fresh_app().await;
    let reply = read(
        send_admin::<()>(
            app.clone(),
            Method::GET,
            "/admin/users",
            crate::app::tests::remote_peer(),
            None,
        )
        .await,
    )
    .await;
    assert_eq!(reply.status, StatusCode::FORBIDDEN);
    assert_problem(&reply, Reason::AdminLoopbackOnly);

    // The same call from the machine itself is served.
    let ok = read(
        send_admin::<()>(
            app,
            Method::GET,
            "/admin/users",
            crate::app::tests::loopback_peer(),
            None,
        )
        .await,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

/// T16: the answers that stay vague for security stay vague.
#[tokio::test]
async fn a_wrong_password_and_an_unknown_account_answer_alike() {
    let (app, _state) = fresh_app().await;
    register(&app, "Alice").await;
    let wrong = call(
        &app,
        Method::POST,
        "/auth/login",
        None,
        Some(json!({"display_name":"Alice","password":"nope","stay_logged_in":false})),
    )
    .await;
    let unknown = call(
        &app,
        Method::POST,
        "/auth/login",
        None,
        Some(json!({"display_name":"Nobody","password":"nope","stay_logged_in":false})),
    )
    .await;
    assert_eq!(wrong.status, unknown.status);
    let (wrong, unknown) = (
        assert_problem(&wrong, Reason::SignInFailed),
        assert_problem(&unknown, Reason::SignInFailed),
    );
    assert_eq!(wrong["detail"], unknown["detail"]);
    assert_eq!(wrong["reason"], unknown["reason"]);

    for email in ["alice@example.com", "nobody@example.com"] {
        let reply = call(
            &app,
            Method::POST,
            "/auth/forgot-password",
            None,
            Some(json!({ "email": email })),
        )
        .await;
        assert_eq!(reply.status, StatusCode::NO_CONTENT, "{email}");
    }

    // And the right password signs in.
    let ok = call(
        &app,
        Method::POST,
        "/auth/login",
        None,
        Some(json!({"display_name":"Alice","password":"correct horse battery staple","stay_logged_in":false})),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
    assert!(ok.json()["session_token"].is_string(), "{}", ok.text);
}

// --- T4: 401 is only "no valid credential"; a rule's refusal is 403 -------------

/// A token that names no session is `SESSION_EXPIRED`, whatever made it so;
/// no token is `SIGN_IN_REQUIRED`.
#[tokio::test]
async fn a_missing_token_and_a_dead_one_are_told_apart() {
    let (app, state) = fresh_app().await;
    let alice = register(&app, "Alice").await;

    let none = call(&app, Method::GET, "/games", None, None).await;
    assert_problem(&none, Reason::SignInRequired);

    let unknown = call(&app, Method::GET, "/games", Some("not-a-token"), None).await;
    assert_problem(&unknown, Reason::SessionExpired);

    // Expired: the session's absolute expiry has passed.
    sqlx::query("update sessions set expires_at = 1")
        .execute(&state.db)
        .await
        .unwrap();
    let expired = call(
        &app,
        Method::GET,
        "/games",
        Some(&alice.session_token),
        None,
    )
    .await;
    assert_problem(&expired, Reason::SessionExpired);

    // Idle: a live session not seen for longer than the idle window.
    let bob = register(&app, "Bob").await;
    sqlx::query("update sessions set last_seen_at = 1 where expires_at is null or expires_at > 1")
        .execute(&state.db)
        .await
        .unwrap();
    let idle = call(&app, Method::GET, "/games", Some(&bob.session_token), None).await;
    assert_problem(&idle, Reason::SessionExpired);

    // A deleted player's: the session resolves, the player does not.
    let carol = register(&app, "Carol").await;
    sqlx::query("delete from players where display_name = 'Carol'")
        .execute(&state.db)
        .await
        .ok();
    let deleted = call(
        &app,
        Method::POST,
        "/auth/change-password",
        Some(&carol.session_token),
        Some(json!({"current_password":"x","new_password":"y"})),
    )
    .await;
    assert!(
        deleted.status == StatusCode::UNAUTHORIZED,
        "a deleted player's token is a 401: {}",
        deleted.text
    );
    assert_problem(&deleted, Reason::SessionExpired);

    // And a live one is served.
    let dave = register(&app, "Dave").await;
    let ok = call(&app, Method::GET, "/games", Some(&dave.session_token), None).await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

/// Each refusal by the application's own rule, once 401 and now 403, followed
/// by the same call succeeding for the one the rule allows.
#[tokio::test]
async fn rule_refusals_are_403_and_the_same_call_succeeds_for_the_right_caller() {
    // Roster calls on a waiting game: the creator-only ones and the seat holder's.
    let (app, _state) = fresh_app().await;
    let g = create_two_human_game_waiting(app.clone()).await;
    let (alice, bob, gid) = (&g.alice.session_token, &g.bob.session_token, &g.game.id);

    let swap = serde_json::to_value(SwapSeatsRequest {
        seat_a: 0,
        seat_b: 1,
    })
    .unwrap();
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/reorder-seats"),
        Some(bob),
        Some(swap.clone()),
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/reorder-seats"),
        Some(alice),
        Some(swap),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    let add = serde_json::to_value(seat(SeatKind::Human, "Zed", Some(SeatClaim::Open))).unwrap();
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats"),
        Some(bob),
        Some(add.clone()),
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats"),
        Some(alice),
        Some(add),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/2/remove"),
        Some(bob),
        None,
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/2/remove"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    // After the swap Bob holds seat 0 and Alice seat 1.
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/0/withdraw"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotYourSeat);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/0/withdraw"),
        Some(bob),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/abort"),
        Some(bob),
        None,
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/abort"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    // Force-resign, on an active game.
    let (app, _state) = fresh_app().await;
    let g = create_two_human_game(app.clone()).await;
    let (alice, bob, gid) = (&g.alice.session_token, &g.bob.session_token, &g.game.id);
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/0/force-resign"),
        Some(bob),
        None,
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/seats/1/force-resign"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    // Invitations: inviting to another's game, and accepting another's invitation.
    let (app, _state) = fresh_app().await;
    let alice = register(&app, "Alice").await;
    let bob = register(&app, "Bob").await;
    let carol = register(&app, "Carol").await;
    let created: GameStateDto = serde_json::from_str(
        &call(
            &app,
            Method::POST,
            "/games",
            Some(&alice.session_token),
            Some(game_request(
                vec![
                    seat(SeatKind::Human, "Alice", Some(SeatClaim::Creator)),
                    seat(SeatKind::Human, "Seat", Some(SeatClaim::Open)),
                ],
                None,
            )),
        )
        .await
        .text,
    )
    .unwrap();
    // A seat added to a waiting game carries no invitation yet.
    let added = call(
        &app,
        Method::POST,
        &format!("/games/{}/seats", created.id),
        Some(&alice.session_token),
        Some(serde_json::to_value(seat(SeatKind::Human, "Seat", Some(SeatClaim::Open))).unwrap()),
    )
    .await;
    assert_eq!(added.status, StatusCode::OK, "{}", added.text);
    let invite = |name: &str, seat_number: u8| {
        serde_json::to_value(InvitePlayerRequest {
            invited_display_name: Some(name.to_string()),
            invited_email: None,
            seat_number,
        })
        .unwrap()
    };
    let uri = format!("/games/{}/invite", created.id);
    let refused = call(
        &app,
        Method::POST,
        &uri,
        Some(&bob.session_token),
        Some(invite("Carol", 2)),
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotGameCreator);
    let ok = call(
        &app,
        Method::POST,
        &uri,
        Some(&alice.session_token),
        Some(invite("Bob", 2)),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
    let invitation: api::GameInvitationDto = serde_json::from_str(&ok.text).unwrap();
    let accept = format!("/invitations/{}/accept", invitation.id);
    let refused = call(
        &app,
        Method::POST,
        &accept,
        Some(&carol.session_token),
        None,
    )
    .await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN, "{}", refused.text);
    assert_problem(&refused, Reason::NotYourInvitation);
    let ok = call(&app, Method::POST, &accept, Some(&bob.session_token), None).await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

/// Starting a game, asking for a suggestion and reordering seats answer 401
/// to a caller with no session, which the first two answered 403 and the third
/// did not check.
#[tokio::test]
async fn start_suggest_and_reorder_without_a_session_are_401_and_succeed_with_one() {
    let (app, _state) = fresh_app().await;
    let g = create_two_human_game_waiting(app.clone()).await;
    let (alice, gid) = (&g.alice.session_token, &g.game.id);
    let swap = serde_json::to_value(SwapSeatsRequest {
        seat_a: 0,
        seat_b: 1,
    })
    .unwrap();

    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/reorder-seats"),
        None,
        Some(swap.clone()),
    )
    .await;
    assert_problem(&refused, Reason::SignInRequired);
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/reorder-seats"),
        Some("dead"),
        Some(swap),
    )
    .await;
    assert_problem(&refused, Reason::SessionExpired);

    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/start"),
        None,
        Some(json!({})),
    )
    .await;
    assert_problem(&refused, Reason::SignInRequired);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/start"),
        Some(alice),
        Some(json!({})),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);

    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/suggest"),
        None,
        None,
    )
    .await;
    assert_problem(&refused, Reason::SignInRequired);
    let refused = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/suggest"),
        Some(&g.bob.session_token),
        None,
    )
    .await;
    assert_problem(&refused, Reason::NotYourSeat);
    let ok = call(
        &app,
        Method::POST,
        &format!("/games/{gid}/suggest"),
        Some(alice),
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

// --- T13: violations ---------------------------------------------------------

#[tokio::test]
async fn a_value_outside_a_stated_limit_names_the_field_value_and_limit() {
    let (app, _state) = fresh_app().await;
    let alice = register(&app, "Alice").await;
    let seats = vec![
        seat(SeatKind::Human, "A", Some(SeatClaim::Creator)),
        seat(SeatKind::Human, "B", Some(SeatClaim::Open)),
    ];

    for (requested, limit) in [
        (5, crate::game_state::MIN_MOVE_TIME_LIMIT_SECONDS),
        (
            crate::game_state::MAX_MOVE_TIME_LIMIT_SECONDS + 1,
            crate::game_state::MAX_MOVE_TIME_LIMIT_SECONDS,
        ),
    ] {
        let reply = call(
            &app,
            Method::POST,
            "/games",
            Some(&alice.session_token),
            Some(game_request(seats.clone(), Some(requested))),
        )
        .await;
        let body = assert_problem(&reply, Reason::MoveTimeLimitOutOfRange);
        let violation = &body["violations"][0];
        assert_eq!(violation["field"], "move_time_limit_seconds");
        assert_eq!(violation["value"], requested);
        assert_eq!(violation["limit"], limit);
        assert_eq!(violation["reason"], "MOVE_TIME_LIMIT_OUT_OF_RANGE");
    }

    // A value inside the limit succeeds.
    let ok = call(
        &app,
        Method::POST,
        "/games",
        Some(&alice.session_token),
        Some(game_request(
            seats,
            Some(crate::game_state::MIN_MOVE_TIME_LIMIT_SECONDS),
        )),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

// --- T5, T20, T7, T15: a response is always a result --------------------------

async fn router_with_odd_routes() -> (Router, AppState) {
    let state = create_test_state(&test_database_url()).await;
    let extra = Router::new()
        .route(
            "/__panic",
            get(|| async { panic!("secret internal words") }),
        )
        .route(
            "/__teapot",
            get(|| async { (StatusCode::IM_A_TEAPOT, "short and stout") }),
        )
        .route("/__ok", get(|| async { "fine" }))
        .route(
            "/__json",
            post(|Json(_): Json<api::CreateSeatRequest>| async { "ok" }),
        );
    (build_router_with(state.clone(), extra), state)
}

/// T5: a panic answers 500 with the body; its words are logged, not sent.
#[tokio::test]
async fn a_panicking_handler_answers_500_and_logs_the_words() {
    let log = start_capturing_log_on_this_thread();
    let (app, _state) = router_with_odd_routes().await;
    let reply = call(&app, Method::GET, "/__panic", None, None).await;
    let body = assert_problem(&reply, Reason::Internal);
    assert_eq!(body["detail"], INTERNAL_MESSAGE);
    assert!(!reply.text.contains("secret internal words"));
    let text = log.text();
    let panic_line = text
        .lines()
        .find(|line| line.contains("a handler panicked"))
        .unwrap_or_else(|| panic!("no panic line in: {text}"));
    assert!(panic_line.contains("ERROR"), "{panic_line}");
    assert!(panic_line.contains("secret internal words"), "{panic_line}");
    assert!(panic_line.contains(&reply.request_id()), "{panic_line}");

    // And the server answers the next request.
    let ok = call(&app, Method::GET, "/__ok", None, None).await;
    assert_eq!(ok.status, StatusCode::OK);
}

/// T20: axum's own rejections answer the body, with their words in the log
/// at `info` and never in the response.
#[tokio::test]
async fn the_frameworks_own_rejections_answer_the_body() {
    let log = start_capturing_log_on_this_thread();
    let (app, _state) = router_with_odd_routes().await;
    let valid = serde_json::to_value(seat(SeatKind::Human, "A", Some(SeatClaim::Open))).unwrap();

    let unknown_route = call(&app, Method::GET, "/no/such/route", None, None).await;
    assert_problem(&unknown_route, Reason::NoSuchRoute);
    let wrong_method = call(&app, Method::DELETE, "/__ok", None, None).await;
    assert_problem(&wrong_method, Reason::MethodNotAllowed);

    let raw = |content_type: Option<&str>, body: String| {
        let mut builder = Request::builder().method(Method::POST).uri("/__json");
        if let Some(content_type) = content_type {
            builder = builder.header("content-type", content_type);
        }
        builder.body(Body::from(body)).unwrap()
    };
    let too_large = read(
        app.clone()
            .oneshot(raw(
                Some("application/json"),
                format!("\"{}\"", "x".repeat(3 * 1024 * 1024)),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_problem(&too_large, Reason::BodyTooLarge);
    let no_type = read(
        app.clone()
            .oneshot(raw(None, valid.to_string()))
            .await
            .unwrap(),
    )
    .await;
    assert_problem(&no_type, Reason::UnsupportedMediaType);
    let malformed = read(
        app.clone()
            .oneshot(raw(Some("application/json"), "{not json".into()))
            .await
            .unwrap(),
    )
    .await;
    assert_problem(&malformed, Reason::MalformedRequest);
    let missing = read(
        app.clone()
            .oneshot(raw(Some("application/json"), "{}".into()))
            .await
            .unwrap(),
    )
    .await;
    assert_problem(&missing, Reason::InvalidBody);
    // ...and the same route succeeds for a valid body.
    let ok = read(
        app.clone()
            .oneshot(raw(Some("application/json"), valid.to_string()))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK);

    for reply in [
        &unknown_route,
        &wrong_method,
        &too_large,
        &no_type,
        &malformed,
        &missing,
    ] {
        for word in [
            "serde",
            "missing field",
            "Failed to",
            "expected",
            "EOF",
            "deserialize",
            "Json",
        ] {
            assert!(!reply.text.contains(word), "{word}: {}", reply.text);
        }
    }

    // An error response the layer does not recognise answers 500 INTERNAL, logged at `error`.
    let teapot = call(&app, Method::GET, "/__teapot", None, None).await;
    let body = assert_problem(&teapot, Reason::Internal);
    assert_eq!(body["detail"], INTERNAL_MESSAGE);
    assert!(!teapot.text.contains("short and stout"));

    let text = log.text();
    let framework_lines: Vec<_> = text
        .lines()
        .filter(|line| line.contains("the framework refused a request"))
        .collect();
    assert_eq!(framework_lines.len(), 6, "{text}");
    assert!(framework_lines.iter().all(|line| line.contains("INFO")));
    assert!(
        text.lines()
            .any(|line| line.contains("short and stout") && line.contains("ERROR")),
        "the unrecognised response is logged at error: {text}"
    );
}

/// The log carries identifiers only: serde echoes the value a caller sent, so
/// the framework's words are logged up to the first quoted value and no further.
#[tokio::test]
async fn the_frameworks_words_are_logged_without_the_callers_values() {
    let log = start_capturing_log_on_this_thread();
    let (app, _state) = router_with_odd_routes().await;
    let reply = call(
        &app,
        Method::POST,
        "/__json",
        None,
        Some(json!({"kind":"bob@example.com","display_name":"x","engine_id":null,"claim":null})),
    )
    .await;
    assert_problem(&reply, Reason::InvalidBody);
    // What the server writes; axum's own TRACE line is below production's filter.
    let text: String = log
        .text()
        .lines()
        .filter(|line| line.contains("server_game::"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(text.contains("the framework refused a request"), "{text}");
    assert!(!text.contains("bob@example.com"), "{text}");
}

/// T7: every response carries a request ID, and the caller cannot choose it.
#[tokio::test]
async fn every_response_carries_a_fresh_request_id_the_caller_cannot_choose() {
    let log = start_capturing_log_on_this_thread();
    let (app, _state) = router_with_odd_routes().await;

    let success = call(&app, Method::GET, "/health", None, None).await;
    assert_eq!(success.status, StatusCode::OK);
    assert!(crockford(&success.request_id()), "{}", success.request_id());

    let error = call(&app, Method::GET, "/games", None, None).await;
    let panic = call(&app, Method::GET, "/__panic", None, None).await;
    for reply in [&error, &panic] {
        assert!(crockford(&reply.request_id()));
    }
    let ids = [success.request_id(), error.request_id(), panic.request_id()];
    assert_eq!(
        ids.iter().collect::<std::collections::HashSet<_>>().len(),
        3,
        "two requests differ"
    );

    // A caller's own header is dropped, not echoed or used.
    let request = Request::builder()
        .uri("/games")
        .header("x-request-id", "FORGED-LOG-LINE")
        .body(Body::empty())
        .unwrap();
    let forged = read(app.clone().oneshot(request).await.unwrap()).await;
    assert_ne!(forged.request_id(), "FORGED-LOG-LINE");
    assert!(crockford(&forged.request_id()));
    assert_eq!(forged.json()["correlation_id"], forged.request_id());
    assert!(!log.text().contains("FORGED-LOG-LINE"));

    // The log line for an error carries the same ID as the body.
    let text = log.text();
    assert!(
        text.lines()
            .any(|line| line.contains("request refused") && line.contains(&error.request_id())),
        "{text}"
    );
}

#[test]
fn a_request_id_is_twelve_crockford_characters_from_sixty_bits() {
    let ids: std::collections::HashSet<String> = (0..2000).map(|_| new_request_id()).collect();
    assert_eq!(ids.len(), 2000);
    assert!(ids.iter().all(|id| crockford(id)));
}

// --- T8: the `request refused` line --------------------------------------------

fn field<'a>(line: &'a str, name: &str) -> Option<&'a str> {
    let start = line.find(&format!("{name}="))? + name.len() + 1;
    let rest = &line[start..];
    let end = rest.find(' ').unwrap_or(rest.len());
    Some(rest[..end].trim_matches('"'))
}

#[tokio::test]
async fn each_error_writes_one_request_refused_line_at_the_level_of_its_type() {
    let log = start_capturing_log_on_this_thread();
    let (app, _state) = router_with_odd_routes().await;

    // (request, expected level): technical is `warn`, unexpected `error`,
    // business `info`.
    let dead_token = call(&app, Method::GET, "/games", Some("bad"), None).await; // 401 technical
    let no_token = call(&app, Method::GET, "/dictionaries/x", None, None).await; // 401 technical
    let panic = call(&app, Method::GET, "/__panic", None, None).await; // 500 unexpected
    let route = call(&app, Method::GET, "/nowhere", None, None).await; // 404 business
    let replies = [
        (dead_token, "WARN"),
        (no_token, "WARN"),
        (panic, "ERROR"),
        (route, "INFO"),
    ];

    let text = log.text();
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| l.contains("request refused"))
        .collect();
    assert_eq!(
        lines.len(),
        replies.len(),
        "exactly one line per error: {text}"
    );
    for (reply, level) in &replies {
        let body = reply.json();
        let matching: Vec<_> = lines
            .iter()
            .filter(|line| field(line, "request_id") == Some(&reply.request_id()))
            .collect();
        assert_eq!(matching.len(), 1, "{}", reply.request_id());
        let line = matching[0];
        assert!(line.contains(level), "{level}: {line}");
        assert_eq!(field(line, "status"), Some(&*body["status"].to_string()));
        assert_eq!(field(line, "error.reason"), body["reason"].as_str());
        assert_eq!(field(line, "error.type"), body["error_type"].as_str());
        assert_eq!(field(line, "error.domain"), Some("tile-lite-elite"));
    }

    // A success writes none.
    let before = log.text().matches("request refused").count();
    call(&app, Method::GET, "/__ok", None, None).await;
    assert_eq!(log.text().matches("request refused").count(), before);

    // The 429 is written at `warn` too; the limiters are off under `cfg(test)`,
    // so that line is asserted where a limiter is built, in `throttle.rs`.
    let _ = ErrorType::Business;
}

// --- T17: busy is 503 with Retry-After, anything else is 500 ---------------------

#[tokio::test]
async fn a_busy_database_answers_503_service_busy_with_retry_after() {
    let (app, state) = fresh_app().await;
    state.db.close().await;
    // Registration reads the players table before anything else.
    let reply = call(
        &app,
        Method::POST,
        "/auth/register",
        None,
        Some(json!({"display_name":"Zed","email":"z@example.com","password":"pw","stay_logged_in":false})),
    )
    .await;
    assert_eq!(reply.status, StatusCode::SERVICE_UNAVAILABLE);
    assert_problem(&reply, Reason::ServiceBusy);
    let retry: u32 = reply
        .headers
        .get("retry-after")
        .expect("Retry-After")
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert_eq!(retry, 2);

    // A service whose database is there registers the same caller.
    let (healthy, _state) = fresh_app().await;
    let ok = call(
        &healthy,
        Method::POST,
        "/auth/register",
        None,
        Some(json!({"display_name":"Zed","email":"z@example.com","password":"pw","stay_logged_in":false})),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

/// The hashing pool's 503 is the same reason, with its own jittered wait.
#[tokio::test]
async fn a_full_hashing_pool_answers_503_service_busy() {
    let mut state = create_test_state(&test_database_url()).await;
    state.hash_limit = std::sync::Arc::new(tokio::sync::Semaphore::new(0));
    let pool = state.hash_limit.clone();
    let app = build_router(state);
    let reply = call(
        &app,
        Method::POST,
        "/auth/register",
        None,
        Some(json!({"display_name":"Zed","email":"z@example.com","password":"pw","stay_logged_in":false})),
    )
    .await;
    assert_problem(&reply, Reason::ServiceBusy);
    let retry: u32 = reply
        .headers
        .get("retry-after")
        .unwrap()
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=3).contains(&retry));

    // With a permit free, the same registration is served.
    pool.add_permits(1);
    let ok = call(
        &app,
        Method::POST,
        "/auth/register",
        None,
        Some(json!({"display_name":"Zed","email":"z@example.com","password":"pw","stay_logged_in":false})),
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}

/// T15: every 500 says the one sentence, which 4.4.3's `Internal` row states.
#[tokio::test]
async fn every_500_carries_the_one_sentence_and_never_says_try_again() {
    let (app, _state) = router_with_odd_routes().await;
    let panic = call(&app, Method::GET, "/__panic", None, None).await;
    let teapot = call(&app, Method::GET, "/__teapot", None, None).await;
    // A database failure that is not load: the table is gone.
    let (app_db, state_db) = fresh_app().await;
    sqlx::query("drop table players")
        .execute(&state_db.db)
        .await
        .unwrap();
    let database = call(
        &app_db,
        Method::POST,
        "/auth/register",
        None,
        Some(json!({"display_name":"Zed","email":"z@example.com","password":"pw","stay_logged_in":false})),
    )
    .await;
    for word in ["no such table", "players", "sqlite"] {
        assert!(!database.text.contains(word), "{}", database.text);
    }
    for reply in [&panic, &teapot, &database] {
        let body = assert_problem(reply, Reason::Internal);
        assert_eq!(body["detail"], INTERNAL_MESSAGE);
        assert!(
            !reply.text.to_lowercase().contains("try again"),
            "{}",
            reply.text
        );
    }
    let doc = include_str!("../../../../docs/4.4.3-api-schema.md");
    assert!(
        doc.lines().any(|line| line.starts_with('|')
            && line.contains("`INTERNAL`")
            && line.contains(INTERNAL_MESSAGE)),
        "4.4.3 has a row naming INTERNAL that states the sentence"
    );
    assert!(!INTERNAL_MESSAGE.to_lowercase().contains("try again"));
}

// --- T10: the WebSocket ------------------------------------------------------------

mod websocket {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    struct Handshake {
        status: u16,
        headers: Vec<(String, String)>,
        body: String,
        stream: TcpStream,
    }

    impl Handshake {
        fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(key, _)| key.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
        }
    }

    async fn serve(state: AppState) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = build_router(state);
        tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await;
        });
        addr
    }

    async fn fixture() -> (
        AppState,
        Router,
        crate::app::tests::TwoHumanGame,
        SocketAddr,
    ) {
        let state = create_test_state(&test_database_url()).await;
        let app = build_router(state.clone());
        let g = create_two_human_game_waiting(app.clone()).await;
        let addr = serve(state.clone()).await;
        (state, app, g, addr)
    }

    async fn connect(addr: SocketAddr, path: &str) -> Handshake {
        let mut stream = TcpStream::connect(addr).await.unwrap();
        let request = format!(
            "GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\
             Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            head.push(stream.read_u8().await.unwrap());
        }
        let head = String::from_utf8(head).unwrap();
        let mut lines = head.split("\r\n");
        let status = lines
            .next()
            .unwrap()
            .split(' ')
            .nth(1)
            .unwrap()
            .parse()
            .unwrap();
        let headers: Vec<(String, String)> = lines
            .filter_map(|line| line.split_once(": "))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let length = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, v)| v.parse::<usize>().ok())
            .unwrap_or(0);
        let mut body = vec![0u8; length];
        if status != 101 {
            stream.read_exact(&mut body).await.unwrap();
        }
        Handshake {
            status,
            headers,
            body: String::from_utf8(body).unwrap(),
            stream,
        }
    }

    /// The next frame's opcode and payload; server frames are never masked.
    async fn frame(stream: &mut TcpStream) -> (u8, Vec<u8>) {
        let first = stream.read_u8().await.unwrap();
        let mut length = (stream.read_u8().await.unwrap() & 0x7f) as usize;
        if length == 126 {
            length = stream.read_u16().await.unwrap() as usize;
        } else if length == 127 {
            length = stream.read_u64().await.unwrap() as usize;
        }
        let mut payload = vec![0u8; length];
        stream.read_exact(&mut payload).await.unwrap();
        (first & 0x0f, payload)
    }

    /// The close code the server sends, skipping any event before it.
    async fn close_code(stream: &mut TcpStream) -> u16 {
        loop {
            let (opcode, payload) =
                tokio::time::timeout(std::time::Duration::from_secs(5), frame(stream))
                    .await
                    .expect("the server closes the socket");
            if opcode == 0x8 {
                return u16::from_be_bytes([payload[0], payload[1]]);
            }
        }
    }

    #[tokio::test]
    async fn the_upgrade_refuses_with_the_designs_reasons_then_a_participant_connects() {
        let state = create_test_state(&test_database_url()).await;
        let app = build_router(state.clone());
        let g = create_two_human_game_waiting(app.clone()).await;
        let stranger = register(&app, "Stranger").await;
        let addr = serve(state).await;
        let gid = &g.game.id;

        let cases = [
            (
                format!("/games/nope/events?token={}", g.alice.session_token),
                Reason::GameNotFound,
            ),
            (format!("/games/{gid}/events"), Reason::SignInRequired),
            (
                format!("/games/{gid}/events?token=dead"),
                Reason::SessionExpired,
            ),
            (
                format!("/games/{gid}/events?token={}", stranger.session_token),
                Reason::NotInGame,
            ),
        ];
        for (path, reason) in cases {
            let refused = connect(addr, &path).await;
            assert_eq!(refused.status, reason.status(), "{path}");
            assert_eq!(
                refused.header("content-type"),
                Some("application/problem+json")
            );
            let body: Value = serde_json::from_str(&refused.body).unwrap();
            assert_eq!(body["reason"], code(reason), "{path}");
            let id = refused
                .header("x-request-id")
                .expect("a refusal carries x-request-id");
            assert!(crockford(id));
            assert_eq!(body["correlation_id"], id);
        }

        let upgraded = connect(
            addr,
            &format!("/games/{gid}/events?token={}", g.bob.session_token),
        )
        .await;
        assert_eq!(upgraded.status, 101);
        assert!(crockford(upgraded.header("x-request-id").unwrap()));
    }

    /// 4404 when its game is deleted, 4500 when the server fails sending, and
    /// 1001 when the server stops.
    #[tokio::test]
    async fn a_live_socket_closes_with_4000_plus_the_status_or_going_away() {
        let (_state, app, g, addr) = fixture().await;
        let path = format!(
            "/games/{}/events?token={}",
            g.game.id, g.alice.session_token
        );

        // Deleted under it: the admin deletes the game over loopback.
        let mut socket = connect(addr, &path).await;
        assert_eq!(socket.status, 101);
        let deleted = send_admin::<()>(
            app.clone(),
            Method::DELETE,
            &format!("/admin/games/{}", g.game.id),
            crate::app::tests::loopback_peer(),
            None,
        )
        .await;
        assert_eq!(deleted.status(), StatusCode::NO_CONTENT);
        assert_eq!(close_code(&mut socket.stream).await, 4404);

        // Sending fails for the server's own reason: the socket fell behind the
        // broadcast. Nothing awaits between these sends, so the receiver lags.
        let (state, _app, g, addr) = fixture().await;
        let path = format!(
            "/games/{}/events?token={}",
            g.game.id, g.alice.session_token
        );
        let mut socket = connect(addr, &path).await;
        assert_eq!(socket.status, 101);
        let dto = state.games.read().await.get(&g.game.id).unwrap().to_dto();
        for _ in 0..200 {
            let _ = state
                .events
                .send(api::GameEventDto::StateUpdated { game: dto.clone() });
        }
        assert_eq!(close_code(&mut socket.stream).await, 4500);

        // The server stops.
        let (state, _app, g, addr) = fixture().await;
        let path = format!(
            "/games/{}/events?token={}",
            g.game.id, g.alice.session_token
        );
        let mut socket = connect(addr, &path).await;
        assert_eq!(socket.status, 101);
        state.begin_shutdown().await;
        assert_eq!(close_code(&mut socket.stream).await, 1001);
    }
}

// --- T6: an engine's fault is a defect, said in the one sentence ------------------

/// An engine that always panics, under the id the registry already lists.
struct PanickingEngine(engine_core::EngineMetadata);

impl engine_core::GameEngine for PanickingEngine {
    fn metadata(&self) -> &engine_core::EngineMetadata {
        &self.0
    }

    fn choose_action(&self, _: engine_core::EngineRequest<'_>) -> engine_core::EngineResponse {
        panic!("the engine blew up on its own words")
    }
}

/// A started game, a human and the engine, with the engine to move.
async fn engine_to_move(panicking: bool) -> (AppState, String) {
    let mut state = create_test_state(&test_database_url()).await;
    let app = build_router_with(state.clone(), Router::new());
    let ann = register(&app, "Ann").await.session_token;
    let engine = CreateSeatRequest {
        kind: SeatKind::Engine,
        display_name: "Greedy".to_string(),
        engine_id: Some("greedy-v1".to_string()),
        claim: None,
    };
    let seats = vec![
        seat(SeatKind::Human, "Ann", Some(SeatClaim::Creator)),
        engine,
    ];
    let created = call(
        &app,
        Method::POST,
        "/games",
        Some(&ann),
        Some(game_request(seats, None)),
    )
    .await;
    let game_id = created.json()["id"].as_str().unwrap().to_string();
    // Started with the engine that works; the registry is swapped after.
    call(
        &app,
        Method::POST,
        &format!("/games/{game_id}/start"),
        Some(&ann),
        Some(json!({})),
    )
    .await;
    {
        let mut games = state.games.write().await;
        let game = games.get_mut(&game_id).expect("the game is in memory");
        assert_eq!(game.status, api::GameStatus::Active);
        game.current_seat = 1;
    }
    if panicking {
        let metadata = engine_core::GameEngine::metadata(&engine_core::GreedyEngine::new()).clone();
        state.engines = crate::game_state::EngineRegistry {
            engines: vec![std::sync::Arc::new(PanickingEngine(metadata))],
        };
    }
    (state, game_id)
}

/// The route that runs the engine's turn the way a handler does, so the answer
/// goes through the request-ID layer and the body is the real one.
fn engine_route(state: AppState) -> Router {
    let extra = Router::new().route(
        "/__engine/{id}",
        get(
            |State(state): State<AppState>, Path(id): Path<String>| async move {
                games::run_engine_turns(&state, &id).await?;
                Ok::<_, ApiProblem>("played")
            },
        ),
    );
    build_router_with(state, extra)
}

#[tokio::test]
async fn an_engine_that_panics_answers_the_one_sentence_and_logs_the_cause() {
    let log = start_capturing_log_on_this_thread();
    let (state, game_id) = engine_to_move(true).await;
    let app = engine_route(state);
    let reply = call(
        &app,
        Method::GET,
        &format!("/__engine/{game_id}"),
        None,
        None,
    )
    .await;
    let body = assert_problem(&reply, Reason::EngineFailed);
    assert_eq!(body["detail"], INTERNAL_MESSAGE);
    for word in ["greedy-v1", "panicked", "blew up"] {
        assert!(
            !reply.text.to_lowercase().contains(word),
            "{word}: {}",
            reply.text
        );
    }
    let logged = log.text();
    let line = logged
        .lines()
        .find(|line| line.contains("a game rule reached a state it should not"))
        .unwrap_or_else(|| panic!("no defect line in {logged}"));
    assert!(line.contains("ERROR"), "{line}");
    assert!(
        line.contains("greedy-v1") && line.contains("blew up"),
        "{line}"
    );
    assert!(line.contains(&reply.request_id()), "{line}");

    // The same turn, with an engine that works, is served.
    let (state, game_id) = engine_to_move(false).await;
    let app = engine_route(state);
    let ok = call(
        &app,
        Method::GET,
        &format!("/__engine/{game_id}"),
        None,
        None,
    )
    .await;
    assert_eq!(ok.status, StatusCode::OK, "{}", ok.text);
}
