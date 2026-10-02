//! An account through the whole life of its games — created, invited, seated,
//! played, ended, swept, and only then deleted.
//!
//! Rules: `docs/1.0-rules.md` — DEL-1 to DEL-9, GAME-1 and GAME-2, RET-1 to
//! RET-4, TIME-1 to TIME-4. Test plan: issue #41.
//!
//! It began as a test of deleting an account and grew into this, because the
//! rule it started from is written in terms of the lifecycle: an account
//! cannot be deleted while a game refers to it, and only the lifecycle clears
//! that reference. Testing the rule means driving games through invitation,
//! roster changes, play, resignation, abort, timeout and retention. Every
//! defect these tests have found so far has been in that machinery rather
//! than in the delete itself.
//!
//! Most tests are a walk rather than a single check — build the thing that
//! attaches an account to a game, watch the delete refused, bring the game to
//! an end, backdate it past the retention window, sweep, then watch the same
//! delete succeed. A test that only proved the refusal would pass just as well
//! against a guard that refused everything, and the second half is what pins
//! the refusal to the attachment rather than to the account.
//!
//! It also puts retention under test. The middle of every walk is a real sweep
//! removing a real game, so a retention bug fails here rather than waiting to
//! be noticed in production — which is how the last one was found.
//!
//! Sequences are what find things. Resign then abort, invite then add a seat:
//! both were fine as states and broken as journeys, so prefer extending a walk
//! over adding a point check.
use super::tests::{
    create_test_state, create_three_human_game, create_two_human_game,
    create_two_human_game_waiting, loopback_peer, read_json, register_player, send_admin,
    send_empty_auth, send_json_auth, test_database_url,
};
use super::*;
use api::{
    CreateSeatRequest, GameActionRequest, GameStateDto, PlayerActionDto, SeatClaim, SeatKind,
};
use axum::body::Body;
use axum::http::Method;

/// Comfortably past RET-1's seven days, so a backdated game is unambiguously
/// old rather than sitting on the boundary.
const WELL_PAST_THE_WINDOW: i64 = 8 * 24 * 60 * 60;

// ---------------------------------------------------------------- the walk

async fn delete_account(app: Router, player_id: &str) -> axum::http::Response<Body> {
    send_admin::<()>(
        app,
        Method::DELETE,
        &format!("/admin/users/{player_id}"),
        loopback_peer(),
        None,
    )
    .await
}

/// DEL-2 refused, and DEL-6 satisfied — the refusal has to name what is in
/// the way. Asserted separately from the status because a dozen different
/// attachments produce the same 400, and without this they would all pass on
/// a refusal that told the operator nothing.
///
/// The games come back as data rather than in the sentence, so that the
/// client can render them however suits it. This checks the data; the CLI
/// test checks that they reach a terminal.
async fn assert_refused(app: Router, player_id: &str, naming: &[&str]) {
    let response = delete_account(app, player_id).await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "an attached account should not be deletable"
    );
    let problem: api::ApiError = read_json(response).await;
    let named: Vec<&str> = problem
        .blocking_games
        .iter()
        .map(|game| game.id.as_str())
        .collect();
    for id in naming {
        assert!(
            named.contains(id),
            "the refusal should name {id}, named: {named:?} ({})",
            problem.message
        );
    }
}

/// An account somebody is signed in as is refused, and told which wait it is in.
///
/// The argument is the games guard's, one step earlier: somebody interested
/// enough to be signed in is likely to play a game, and a game is exactly what
/// that guard protects. The tool exists to clear out *old* data, and a live
/// session is the clearest evidence that this is not old data.
///
/// Refused *and* explained, separately from the games refusal, because the
/// remedies differ — one waits for retention, the other for the session. A test
/// that only checked the 400 would pass against a refusal that told the
/// operator nothing, which is the failure this file already guards against for
/// the games case.
#[tokio::test]
async fn cannot_delete_an_account_that_is_signed_in() {
    let database_url = test_database_url();
    let state = create_test_state(&database_url).await;
    let app = build_router(state.clone());

    // No games at all: this account is deletable but for the session.
    let alice = register_player(app.clone(), "Alice").await;

    let response = delete_account(app.clone(), &alice.player_id).await;
    assert_eq!(
        response.status(),
        StatusCode::BAD_REQUEST,
        "an account in use should not be deleted out from under whoever is using it"
    );
    let problem: api::ApiError = read_json(response).await;
    assert!(
        problem.message.contains("signed in"),
        "the refusal should say it is the session in the way, not leave the \
         operator to guess between this and the games guard: {}",
        problem.message
    );

    // Signing out removes the only thing in the way.
    persistence::invalidate_sessions_for_player(&state.db, &alice.player_id)
        .await
        .expect("sessions should be removable");
    assert_deleted(app, &state, &alice.player_id).await;
}

/// Signs the account out first, then deletes it.
///
/// Registering creates a session, so every account in this file is signed in —
/// and a live session is now its own refusal (#82). These tests are about the
/// *games* guard, so the session is setup rather than subject: ending it here
/// keeps each test asserting the one thing it was written for. The session
/// refusal has its own test below.
async fn assert_deleted(app: Router, state: &AppState, player_id: &str) {
    persistence::invalidate_sessions_for_player(&state.db, player_id)
        .await
        .expect("sessions should be removable");
    let response = delete_account(app, player_id).await;
    assert_eq!(
        response.status(),
        StatusCode::NO_CONTENT,
        "an unattached, signed-out account should be deletable"
    );
}

async fn game_rows(state: &AppState, game_id: &str) -> i64 {
    sqlx::query_scalar::<_, i64>("select count(*) from games where id = ?1")
        .bind(game_id)
        .fetch_one(&state.db)
        .await
        .expect("counting games should work")
}

/// Both sweeps are lazy — no scheduler in this server — so listing games is
/// what runs them (`sweeps::expire_overdue_turns`, `expire_old_terminal_games`).
async fn trigger_sweeps(app: Router, token: &str) {
    let response = send_empty_auth(app, Method::GET, "/games", Some(token)).await;
    assert_eq!(response.status(), StatusCode::OK);
}

/// Backdate a terminal game past RET-1 and let the sweep take it.
///
/// `ended_at` is a column and lives only in SQL, so this is a plain update —
/// unlike `turn_started_at`, which is a field inside `snapshot_json`.
async fn sweep_away(app: Router, state: &AppState, game_id: &str, token: &str) {
    let ended = now_unix_seconds() - WELL_PAST_THE_WINDOW;
    sqlx::query("update games set ended_at = ?1 where id = ?2")
        .bind(ended)
        .bind(game_id)
        .execute(&state.db)
        .await
        .expect("backdating the end should work");

    trigger_sweeps(app, token).await;

    assert_eq!(
        game_rows(state, game_id).await,
        0,
        "the sweep should have removed a game {} days past the window",
        WELL_PAST_THE_WINDOW / 86_400
    );
    assert!(
        !state.games.read().await.contains_key(game_id),
        "a swept game should leave the loaded set too, not only the database"
    );
}

// ------------------------------------------------------------- game set-up

fn human(display_name: &str, claim: Option<SeatClaim>) -> CreateSeatRequest {
    CreateSeatRequest {
        kind: SeatKind::Human,
        display_name: display_name.to_string(),
        engine_id: None,
        claim,
    }
}

fn engine(display_name: &str) -> CreateSeatRequest {
    CreateSeatRequest {
        kind: SeatKind::Engine,
        display_name: display_name.to_string(),
        engine_id: Some("greedy-v1".to_string()),
        claim: None,
    }
}

async fn create_game(app: Router, token: &str, seats: Vec<CreateSeatRequest>) -> GameStateDto {
    let response = send_json_auth(
        app,
        Method::POST,
        "/games",
        Some(token),
        &CreateGameRequest {
            seats,
            seed: Some(42),
            variant: None,
            language: None,
            board_layout: None,
            move_time_limit_seconds: None,
        },
    )
    .await;
    let status = response.status();
    if status != StatusCode::OK {
        let body: serde_json::Value = read_json(response).await;
        panic!("creating the game should succeed, got {status}: {body}");
    }
    read_json(response).await
}

/// Alice, with an unstarted game whose second seat is open to anyone and has
/// no taker.
///
/// This stands in for "the creator built a roster and asked nobody", which
/// cannot actually arise: every human seat needs a claim at creation, and
/// each claim creates an invitation, so `SeatInvitationStatus::NotSent` is
/// unreachable through the API for a seat that exists.
async fn alice_with_an_open_seat(app: Router) -> (PlayerSessionDto, GameStateDto) {
    let alice = register_player(app.clone(), "Alice").await;
    let game = create_game(
        app,
        &alice.session_token,
        vec![
            human("Alice", Some(SeatClaim::Creator)),
            human("Second seat", Some(SeatClaim::Open)),
        ],
    )
    .await;
    (alice, game)
}

/// Alice, having asked Bob by name for the second seat. He has not answered.
async fn alice_having_asked_bob(app: Router) -> (PlayerSessionDto, PlayerSessionDto, GameStateDto) {
    let alice = register_player(app.clone(), "Alice").await;
    let bob = register_player(app.clone(), "Bob").await;
    let game = create_game(
        app.clone(),
        &alice.session_token,
        vec![
            human("Alice", Some(SeatClaim::Creator)),
            human(
                "Bob",
                Some(SeatClaim::Named {
                    display_name: "Bob".to_string(),
                }),
            ),
        ],
    )
    .await;
    (alice, bob, game)
}

/// The pending invitation on a seat, as the invitee sees it in their own
/// games list — the path a real client uses to find one.
async fn invitation_for(app: Router, game_id: &str, token: &str) -> String {
    let games: Vec<api::GameSummaryDto> =
        read_json(send_empty_auth(app, Method::GET, "/games", Some(token)).await).await;
    games
        .iter()
        .find(|summary| summary.id == game_id)
        .expect("an invited player should see the game")
        .invitation_id
        .clone()
        .expect("an invited entry should carry an invitation id")
}

async fn decline(app: Router, invitation_id: &str, token: &str) {
    let response = send_empty_auth(
        app,
        Method::POST,
        &format!("/invitations/{invitation_id}/reject"),
        Some(token),
    )
    .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "declining should succeed"
    );
}

async fn abort(app: Router, game_id: &str, token: &str) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/abort"),
        Some(token),
        &serde_json::json!({}),
    )
    .await;
    let status = response.status();
    if status != StatusCode::OK {
        let body: serde_json::Value = read_json(response).await;
        panic!("aborting should succeed, got {status}: {body}");
    }
}

async fn resign(app: Router, game_id: &str, token: &str, seat: u8) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/actions"),
        Some(token),
        &GameActionRequest {
            seat_number: seat,
            action: PlayerActionDto::Resign,
        },
    )
    .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "resigning should succeed"
    );
}

async fn pass_turn(app: Router, game_id: &str, token: &str, seat: u8) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/actions"),
        Some(token),
        &GameActionRequest {
            seat_number: seat,
            action: PlayerActionDto::Pass,
        },
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "passing should succeed");
}

async fn hide_from_my_list(app: Router, game_id: &str, token: &str) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/remove"),
        Some(token),
        &serde_json::json!({}),
    )
    .await;
    assert_eq!(response.status(), StatusCode::OK, "removing should succeed");
}

// ============================================================== S1 to S4
// The four situations an unstarted game can be in. The refusal is the same
// in all four, which is the point: it does not care how far the game got.

#[tokio::test]
async fn cannot_delete_a_creator_of_an_unstarted_game_with_an_open_seat() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, game) = alice_with_an_open_seat(app.clone()).await;

    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_while_an_invitation_is_outstanding() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, _bob, game) = alice_having_asked_bob(app.clone()).await;

    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_after_an_invitation_is_declined() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;
    let invitation = invitation_for(app.clone(), &game.id, &bob.session_token).await;
    decline(app.clone(), &invitation, &bob.session_token).await;

    // Declining releases Bob (DEL-3) but does nothing for Alice, who still
    // created the game.
    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_of_a_game_ready_to_start() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let waiting = create_two_human_game_waiting(app.clone()).await;

    assert_refused(app.clone(), &waiting.alice.player_id, &[&waiting.game.id]).await;

    abort(app.clone(), &waiting.game.id, &waiting.alice.session_token).await;
    sweep_away(
        app.clone(),
        &state,
        &waiting.game.id,
        &waiting.alice.session_token,
    )
    .await;

    assert_deleted(app, &state, &waiting.alice.player_id).await;
}

// ============================================================== S5 to S11

#[tokio::test]
async fn cannot_delete_a_player_seated_in_a_game_in_play() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;

    // Bob holds a seat he did not create — the seat arm of DEL-2 on its own.
    // Alice is refused too, holding both a seat and the game she made.
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;

    let force_end = send_admin::<()>(
        app.clone(),
        Method::POST,
        &format!("/admin/games/{}/force-end", playing.game.id),
        loopback_peer(),
        None,
    )
    .await;
    assert_eq!(force_end.status(), StatusCode::OK);

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app, &state, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_until_their_finished_game_is_swept() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    // Two seats, so one resignation leaves one player and finishes the game.
    resign(
        app.clone(),
        &playing.game.id,
        &playing.alice.session_token,
        0,
    )
    .await;

    // Finished, but inside the window — a game that has ended still refuses,
    // for the player who created it and for the one who merely sat in it.
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;

    assert_deleted(app, &state, &playing.alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_creator_who_took_no_seat() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let alice = register_player(app.clone(), "Alice").await;
    let game = create_game(
        app.clone(),
        &alice.session_token,
        vec![engine("Greedy One"), engine("Greedy Two")],
    )
    .await;

    // The creator arm of DEL-2 on its own: Alice holds no seat at all.
    assert_refused(app.clone(), &alice.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &alice.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_who_resigned_while_the_game_continued() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    // Bob resigns on his own turn. Resigning off-turn is allowed but leaves
    // the game unable to record another move (#62), so a walk that has to
    // reach an end state cannot use it — the game would be stuck rather than
    // swept, and this test would be asserting that bug instead of the rule.
    pass_turn(
        app.clone(),
        &playing.game.id,
        &playing.alice.session_token,
        0,
    )
    .await;
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;

    // Three seats, so Bob leaving does not end the game — and the seat he
    // gave up still refers to him.
    assert!(
        state
            .games
            .read()
            .await
            .get(&playing.game.id)
            .map(|game| game.status == api::GameStatus::Active)
            .unwrap_or(false),
        "a three-player game should carry on after one seat resigns"
    );
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;
    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app, &state, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_either_player_of_an_aborted_game() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;

    // GAME-1: aborting gives up every seat, so neither of them holds a seat
    // they have not given up — and both are still refused.
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    assert_deleted(app.clone(), &state, &playing.alice.player_id).await;
    assert_deleted(app, &state, &playing.bob.player_id).await;
}

#[tokio::test]
async fn cannot_delete_a_player_with_an_unanswered_invitation() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;

    // DEL-2's third arm. Bob holds no seat and created nothing — only an
    // invitation he has not answered.
    assert_refused(app.clone(), &bob.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &bob.player_id).await;
}

/// Inviting somebody and then changing the roster is ordinary behaviour, and
/// invitations are keyed on seat number — so this checks the invitation still
/// refers to the invitee, and still holds their account, after the roster it
/// was written against has moved underneath it.
#[tokio::test]
async fn adding_a_seat_leaves_an_earlier_invitation_holding_its_invitee() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;

    let added = send_json_auth(
        app.clone(),
        Method::POST,
        &format!("/games/{}/seats", game.id),
        Some(&alice.session_token),
        &human("Third seat", Some(SeatClaim::Open)),
    )
    .await;
    assert_eq!(added.status(), StatusCode::OK, "adding a seat should work");

    // Bob keeps seat 1 — a seat is appended rather than inserted — so his
    // invitation still points at the seat it was written for.
    let after: GameStateDto = read_json(
        send_empty_auth(
            app.clone(),
            Method::GET,
            &format!("/games/{}", game.id),
            Some(&alice.session_token),
        )
        .await,
    )
    .await;
    assert_eq!(after.participants.len(), 3, "the roster should have grown");
    assert_eq!(
        after.participants[1].display_name, "Bob",
        "an added seat should not renumber the seats before it"
    );

    assert_refused(app.clone(), &bob.player_id, &[&game.id]).await;

    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app, &state, &bob.player_id).await;
}

#[tokio::test]
async fn hiding_a_game_does_not_make_its_players_deletable() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    resign(
        app.clone(),
        &playing.game.id,
        &playing.alice.session_token,
        0,
    )
    .await;

    hide_from_my_list(app.clone(), &playing.game.id, &playing.alice.session_token).await;
    hide_from_my_list(app.clone(), &playing.game.id, &playing.bob.session_token).await;

    // DEL-5. Both lists are empty, so from the outside the accounts look
    // unattached — and neither can be deleted.
    let alice_games: Vec<api::GameSummaryDto> = read_json(
        send_empty_auth(
            app.clone(),
            Method::GET,
            "/games",
            Some(&playing.alice.session_token),
        )
        .await,
    )
    .await;
    assert!(
        alice_games.is_empty(),
        "removing the only game should leave an empty list"
    );

    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.bob.player_id, &[&playing.game.id]).await;

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;

    assert_deleted(app.clone(), &state, &playing.alice.player_id).await;
    assert_deleted(app, &state, &playing.bob.player_id).await;
}

// =================================== deleting when no game is in the way

async fn count(state: &AppState, sql: &str, id: &str) -> i64 {
    sqlx::query_scalar::<_, i64>(sql)
        .bind(id)
        .fetch_one(&state.db)
        .await
        .expect("counting should work")
}

async fn personal_rows(state: &AppState, player_id: &str) -> (i64, i64, i64, i64) {
    (
        count(state, "select count(*) from sessions where player_id = ?1", player_id).await,
        count(
            state,
            "select count(*) from player_ratings where subject_kind = 'player' and subject_id = ?1",
            player_id,
        )
        .await,
        count(
            state,
            "select count(*) from rating_history where subject_kind = 'player' and subject_id = ?1",
            player_id,
        )
        .await,
        count(
            state,
            "select count(*) from game_invitations where invited_player_id = ?1 or inviting_player_id = ?1",
            player_id,
        )
        .await,
    )
}

/// ACC-3's second half. Rating history outlives the games it came from — that
/// is what makes retention acceptable — and then goes with the account. The
/// game is swept first so the account is unattached and the delete is about
/// nothing but the personal data.
#[tokio::test]
async fn deleting_an_account_takes_everything_personal_and_nothing_else() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;
    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    let (sessions, rating, history, invitations) =
        personal_rows(&state, &playing.bob.player_id).await;
    assert!(sessions > 0, "Bob should be signed in");
    assert!(rating > 0, "playing a rated game should give Bob a rating");
    assert!(history > 0, "and rating history, which outlived the game");
    assert_eq!(
        invitations, 0,
        "the game took its invitations when it was swept (DEL-4), which is \
         what stops one holding an account open forever"
    );

    assert_deleted(app.clone(), &state, &playing.bob.player_id).await;

    assert_eq!(
        personal_rows(&state, &playing.bob.player_id).await,
        (0, 0, 0, 0),
        "sessions, rating and history should all go with him"
    );

    // His token stops working, rather than merely being unfindable.
    let with_dead_token = send_empty_auth(
        app.clone(),
        Method::GET,
        "/games",
        Some(&playing.bob.session_token),
    )
    .await;
    assert_eq!(
        with_dead_token.status(),
        StatusCode::UNAUTHORIZED,
        "a deleted account's token should be rejected"
    );

    // Alice is untouched — the thing nothing else would notice.
    let (alice_sessions, alice_rating, alice_history, _) =
        personal_rows(&state, &playing.alice.player_id).await;
    assert!(alice_sessions > 0, "Alice should still be signed in");
    assert!(alice_rating > 0, "Alice should still have her rating");
    assert!(alice_history > 0, "and her own rating history");
}

#[tokio::test]
async fn deleting_an_unknown_account_is_not_found() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let response = delete_account(app, "no-such-player-id").await;
    assert_eq!(
        response.status(),
        StatusCode::NOT_FOUND,
        "DEL-8: an account that never existed reads differently from one that \
         exists and is refused"
    );
}

/// DEL-3. Declining answers the invitation but does not detach the invitee:
/// the seat it was for still carries their name, so deleting them would leave
/// the roster offering a seat to somebody who no longer exists. Found user
/// testing on preview, where exactly that happened.
#[tokio::test]
async fn declining_an_invitation_does_not_release_the_account() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let (alice, bob, game) = alice_having_asked_bob(app.clone()).await;
    let invitation = invitation_for(app.clone(), &game.id, &bob.session_token).await;
    decline(app.clone(), &invitation, &bob.session_token).await;

    assert_refused(app.clone(), &bob.player_id, &[&game.id]).await;

    // The game going is what clears it, for the invitee as much as for the
    // players — there is nothing either of them can do to the roster.
    abort(app.clone(), &game.id, &alice.session_token).await;
    sweep_away(app.clone(), &state, &game.id, &alice.session_token).await;

    assert_deleted(app.clone(), &state, &bob.player_id).await;
    assert_deleted(app, &state, &alice.player_id).await;
}

// ================================================ retention on its own

/// RET-1 keeps what is inside the window and takes what is outside it. The
/// unstarted game is here because RET-3's countdown is decided but not built,
/// so it is kept by the absence of a rule rather than by one — this fails the
/// day the keep prompt lands, which is the reminder to revisit it.
#[tokio::test]
async fn retention_sweeps_games_past_the_window_and_keeps_the_rest() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let alice = register_player(app.clone(), "Alice").await;
    let mut ended = Vec::new();
    for _ in 0..2 {
        let game = create_game(
            app.clone(),
            &alice.session_token,
            vec![
                human("Alice", Some(SeatClaim::Creator)),
                human("Second seat", Some(SeatClaim::Open)),
            ],
        )
        .await;
        abort(app.clone(), &game.id, &alice.session_token).await;
        ended.push(game.id);
    }
    let unstarted = create_game(
        app.clone(),
        &alice.session_token,
        vec![
            human("Alice", Some(SeatClaim::Creator)),
            human("Second seat", Some(SeatClaim::Open)),
        ],
    )
    .await;

    let now = now_unix_seconds();
    for (game_id, ended_at) in [
        (&ended[0], now - 8 * 24 * 60 * 60),
        (&ended[1], now - 6 * 24 * 60 * 60),
    ] {
        sqlx::query("update games set ended_at = ?1 where id = ?2")
            .bind(ended_at)
            .bind(game_id)
            .execute(&state.db)
            .await
            .expect("backdating should work");
    }

    trigger_sweeps(app, &alice.session_token).await;

    assert_eq!(game_rows(&state, &ended[0]).await, 0, "8 days old: swept");
    assert_eq!(game_rows(&state, &ended[1]).await, 1, "6 days old: kept");
    assert_eq!(
        game_rows(&state, &unstarted.id).await,
        1,
        "unstarted: kept, because RET-3 is not built yet"
    );
}

/// The regression guard for the loss fixed in #54: retention took rating
/// history with every game it swept, so a rating graph emptied itself a week
/// after each game. ACC-3 says the history belongs to the player.
#[tokio::test]
async fn retention_keeps_rating_history_when_it_sweeps_a_game() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;

    let before = count(
        &state,
        "select count(*) from rating_history where game_id = ?1",
        &playing.game.id,
    )
    .await;
    assert!(before > 0, "a finished rated game should record history");

    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.alice.session_token,
    )
    .await;

    let after = count(
        &state,
        "select count(*) from rating_history where game_id = ?1",
        &playing.game.id,
    )
    .await;
    assert_eq!(
        after, before,
        "every history row should outlive the game that produced it"
    );
}

// ============================================== a game in play ends itself

/// Push the seat on turn past its move time limit. `turn_started_at` lives on
/// the loaded session and inside `snapshot_json` rather than in a column, so
/// this sets it where the sweep reads it and then persists.
async fn run_the_clock_out(state: &AppState, game_id: &str) {
    let mut games = state.games.write().await;
    let game = games.get_mut(game_id).expect("the game should be loaded");
    game.turn_started_at = now_unix_seconds() - game.move_time_limit_seconds as i64 - 60;
    persistence::save_game(&state.db, game)
        .await
        .expect("persisting the backdated turn should work");
}

/// Leaving a game in play out of retention rests entirely on this: every game
/// carries a move time limit, a seat that overruns is retired, and the game
/// finishes once one seat is left — so it becomes a completed game and RET-1
/// takes it from there. Nobody resigns and nobody aborts here.
#[tokio::test]
async fn a_game_in_play_ends_itself_when_the_clock_runs_out() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;
    let bag_before = state
        .games
        .read()
        .await
        .get(&playing.game.id)
        .expect("loaded")
        .bag
        .len();

    run_the_clock_out(&state, &playing.game.id).await;
    trigger_sweeps(app.clone(), &playing.alice.session_token).await;

    {
        let games = state.games.read().await;
        let game = games.get(&playing.game.id).expect("still loaded");
        assert!(
            game.participants[0].resigned,
            "the seat that ran out of time should be retired"
        );
        assert!(
            game.bag.len() > bag_before,
            "and the tiles it held should be back in the bag"
        );
        assert_eq!(
            game.status,
            api::GameStatus::Finished,
            "two seats, so retiring one leaves one playing and ends the game"
        );
    }

    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;
    assert_deleted(app, &state, &playing.alice.player_id).await;
}

/// The same clock in a game that does not end because of it — and the seat it
/// retires still refers to its player, exactly as a resigned one does.
#[tokio::test]
async fn a_timed_out_seat_leaves_the_others_playing() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    run_the_clock_out(&state, &playing.game.id).await;
    trigger_sweeps(app.clone(), &playing.alice.session_token).await;

    {
        let games = state.games.read().await;
        let game = games.get(&playing.game.id).expect("still loaded");
        assert!(
            game.participants[0].resigned,
            "the seat on turn should be retired"
        );
        assert_eq!(
            game.status,
            api::GameStatus::Active,
            "three seats, so the other two carry on"
        );
    }

    // Alice's seat is retired; Bob and Carol are still playing. All three are
    // refused, by a given-up seat and by two held ones.
    assert_refused(app.clone(), &playing.alice.player_id, &[&playing.game.id]).await;
    assert_refused(app.clone(), &playing.carol.player_id, &[&playing.game.id]).await;

    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;
    sweep_away(
        app.clone(),
        &state,
        &playing.game.id,
        &playing.bob.session_token,
    )
    .await;
    assert_deleted(app, &state, &playing.alice.player_id).await;
}

/// DEL-6 says the refusal names the games responsible, and an id alone does
/// not tell an operator whether to delete a game or wait for it. This pins
/// the description as well as the id, because the message is read by a person
/// deciding what to do next and nothing else in the suite would notice it
/// turning back into a list of UUIDs.
#[tokio::test]
async fn the_refusal_says_who_is_in_each_game_and_where_it_has_got_to() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    let playing = create_two_human_game(app.clone()).await;

    let response = delete_account(app, &playing.alice.player_id).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let problem: api::ApiError = read_json(response).await;

    assert_eq!(problem.blocking_games.len(), 1, "one game is in the way");
    let blocking = &problem.blocking_games[0];
    assert_eq!(
        blocking.id, playing.game.id,
        "the id is what identifies the game to every other command"
    );
    assert_eq!(
        blocking.status,
        api::GameStatus::Active,
        "what state it is in decides whether waiting is reasonable"
    );
    let seats = api::describe_seats(blocking.status, &blocking.participants);
    assert!(
        seats.contains("Alice") && seats.contains("Bob"),
        "and who is in it decides whether it will move: {seats}"
    );
    assert!(
        blocking.last_activity_at > 0,
        "the listing shows last activity, so this must carry it too"
    );

    // Free of counts and agreement — the list carries the detail, and there
    // may be one game or a dozen in any mix of states.
    assert!(
        !problem.message.contains("game(s)") && !problem.message.contains("1 game"),
        "the sentence should not try to count what the table shows: {}",
        problem.message
    );
    assert!(
        problem.message.contains("wait") && !problem.message.contains("Delete those games"),
        "waiting is the advice — deleting somebody else's game to hurry a \
         cleanup along is not: {}",
        problem.message
    );
}

// ====================================== a game can always record what happens

async fn force_resign(app: Router, game_id: &str, seat: u8, token: &str) {
    let response = send_json_auth(
        app,
        Method::POST,
        &format!("/games/{game_id}/seats/{seat}/force-resign"),
        Some(token),
        &serde_json::json!({}),
    )
    .await;
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "the creator should be able to retire a seat"
    );
}

/// Whatever the players were shown, a restart must agree with it.
///
/// Every handler changes the loaded session first and writes afterwards, so a
/// failed write leaves memory holding something the database does not — and
/// memory answers every read until the server restarts. Reloading is the only
/// way a test can tell the difference.
async fn status_after_reload(database_url: &str, game_id: &str) -> api::GameStatus {
    let reloaded = create_test_state(database_url).await;
    let games = reloaded.games.read().await;
    games
        .get(game_id)
        .expect("the game should reload from the database")
        .status
}

/// Retiring a seat that is not the one on turn records something without the
/// game moving on. Anything recorded next must still be able to take a number
/// of its own — this used to collide, the write rolled back, and the players
/// were shown an abort the database never received.
#[tokio::test]
async fn a_game_can_be_aborted_after_a_seat_is_retired_off_turn() {
    let database_url = test_database_url();
    let state = create_test_state(&database_url).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    // Seat 0 is on turn, so retiring seat 1 does not advance the game.
    force_resign(
        app.clone(),
        &playing.game.id,
        1,
        &playing.alice.session_token,
    )
    .await;
    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;

    assert_eq!(
        status_after_reload(&database_url, &playing.game.id).await,
        api::GameStatus::Aborted,
        "the abort the players saw must be the abort the database holds"
    );
}

/// The same collision reached by the other door: a player resigning when it is
/// not their turn, and then the game carrying on.
#[tokio::test]
async fn play_continues_after_a_player_resigns_off_turn() {
    let database_url = test_database_url();
    let state = create_test_state(&database_url).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    // Bob is seat 1 and it is seat 0's turn.
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;
    pass_turn(
        app.clone(),
        &playing.game.id,
        &playing.alice.session_token,
        0,
    )
    .await;

    assert_eq!(
        status_after_reload(&database_url, &playing.game.id).await,
        api::GameStatus::Active,
        "two seats are still playing, and the pass must have persisted"
    );
}

/// Two retirements in a row, neither of them the seat on turn — the case that
/// needs the record number to be a sequence rather than the turn, since the
/// turn never moves across either of them.
#[tokio::test]
async fn two_seats_can_be_retired_off_turn_in_a_row() {
    let database_url = test_database_url();
    let state = create_test_state(&database_url).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;

    force_resign(
        app.clone(),
        &playing.game.id,
        1,
        &playing.alice.session_token,
    )
    .await;
    force_resign(
        app.clone(),
        &playing.game.id,
        2,
        &playing.alice.session_token,
    )
    .await;

    // One seat left playing, so the game finishes itself (GAME-2).
    assert_eq!(
        status_after_reload(&database_url, &playing.game.id).await,
        api::GameStatus::Finished,
        "retiring the last two opponents should end the game, and persist"
    );
}

/// Records are numbered in the order they happened, with no repeats. Rating
/// leans on that order to rank resigners against each other (`stats.rs`), and
/// persistence derives each row's id from the number.
#[tokio::test]
async fn every_record_takes_its_own_number_in_order() {
    let database_url = test_database_url();
    let state = create_test_state(&database_url).await;
    let app = build_router(state.clone());

    let playing = create_three_human_game(app.clone()).await;
    resign(app.clone(), &playing.game.id, &playing.bob.session_token, 1).await;
    pass_turn(
        app.clone(),
        &playing.game.id,
        &playing.alice.session_token,
        0,
    )
    .await;
    abort(app.clone(), &playing.game.id, &playing.alice.session_token).await;

    let numbers: Vec<i64> = sqlx::query_scalar(
        "select move_number from game_moves where game_id = ?1 order by move_number",
    )
    .bind(&playing.game.id)
    .fetch_all(&state.db)
    .await
    .expect("reading the records should work");

    assert!(numbers.len() >= 3, "three things happened: {numbers:?}");
    let mut unique = numbers.clone();
    unique.dedup();
    assert_eq!(unique, numbers, "no number is used twice: {numbers:?}");
    assert!(
        numbers.windows(2).all(|pair| pair[0] < pair[1]),
        "and they only go up: {numbers:?}"
    );
}

// ================================ what a timeout tells the players who remain

/// A clock running out retires the seat on turn. Whether that ends the *game*
/// depends on how many seats are left playing, and the announcement has to say
/// which happened — telling the remaining players a game is over while they
/// are still in it is worse than telling them nothing.
#[tokio::test]
async fn a_timeout_announces_a_finish_only_when_the_game_finishes() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());

    // Three seats: retiring one leaves two playing, so the game carries on.
    let three = create_three_human_game(app.clone()).await;
    let mut events = state.events.subscribe();
    run_the_clock_out(&state, &three.game.id).await;
    trigger_sweeps(app.clone(), &three.alice.session_token).await;

    let mut announced_finished = false;
    let mut announced_update = false;
    while let Ok(event) = events.try_recv() {
        match event {
            GameEventDto::GameFinished { game } if game.id == three.game.id => {
                announced_finished = true;
            }
            GameEventDto::StateUpdated { game } if game.id == three.game.id => {
                announced_update = true;
            }
            _ => {}
        }
    }
    assert!(
        announced_update,
        "the seat going should reach the two still playing"
    );
    assert!(
        !announced_finished,
        "but not as a finish — they are still in the game"
    );

    // Two seats: retiring one leaves one, so the game really does end.
    let two = create_two_human_game(app.clone()).await;
    let mut events = state.events.subscribe();
    run_the_clock_out(&state, &two.game.id).await;
    trigger_sweeps(app.clone(), &two.alice.session_token).await;

    let mut finished_dto = None;
    while let Ok(event) = events.try_recv() {
        if let GameEventDto::GameFinished { game } = event
            && game.id == two.game.id
        {
            finished_dto = Some(game);
        }
    }
    let finished = finished_dto.expect("the last seat standing should end the game");
    assert_eq!(finished.status, api::GameStatus::Finished);
}
