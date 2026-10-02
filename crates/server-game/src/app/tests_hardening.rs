//! Who may act, and what a request may carry: the checks made where a
//! request enters the server, before any game logic runs.
//!
//! Each test here was shown red before the check it covers existed.

use super::*;
use crate::app::tests::{
    create_claimed_game_and_second_player, create_test_state, read_json, register_player,
    send_empty, send_empty_auth, send_json_auth, test_database_url,
};
use api::{
    CreateSeatRequest, DirectionDto, GameStateDto, GameSummaryDto, MoveCandidateDto, PositionDto,
    SeatClaim, SeatKind, TileDto, TilePlacementDto,
};
use axum::http::Method;

fn one_tile(letter: &str, x: u8, y: u8, offset: u8) -> MoveCandidateDto {
    MoveCandidateDto {
        start: PositionDto { x, y },
        direction: DirectionDto::Horizontal,
        tiles: vec![TilePlacementDto {
            offset,
            tile: TileDto::Letter {
                letter: letter.to_string(),
            },
        }],
    }
}

async fn build_router_for_test() -> Router {
    build_router(create_test_state(&test_database_url()).await)
}

async fn game_status(app: Router, game_id: &str, token: &str) -> api::GameStatus {
    let game: GameStateDto = read_json(
        send_empty_auth(app, Method::GET, &format!("/games/{game_id}"), Some(token)).await,
    )
    .await;
    game.status
}

/// An engine seat has no owner, and that must not make it everyone's. Only a
/// signed-in caller holding a human seat may act for that seat; nobody may
/// act for an engine's, through this endpoint or the preview.
#[tokio::test]
async fn nobody_may_act_for_an_engine_seat() {
    let app = build_router_for_test().await;
    let (alice, mallory, created) =
        create_claimed_game_and_second_player(app.clone(), SeatKind::Engine).await;
    let started = send_json_auth(
        app.clone(),
        Method::POST,
        &format!("/games/{}/start", created.id),
        Some(&alice.session_token),
        &StartGameRequest::default(),
    )
    .await;
    assert_eq!(started.status(), StatusCode::OK);

    let resign_engine = GameActionRequest {
        seat_number: 1,
        action: PlayerActionDto::Resign,
    };
    let actions = format!("/games/{}/actions", created.id);

    let anonymous = send_json_auth(app.clone(), Method::POST, &actions, None, &resign_engine).await;
    assert_eq!(
        anonymous.status(),
        StatusCode::UNAUTHORIZED,
        "no session at all"
    );

    let other = send_json_auth(
        app.clone(),
        Method::POST,
        &actions,
        Some(&mallory.session_token),
        &resign_engine,
    )
    .await;
    assert_eq!(
        other.status(),
        StatusCode::FORBIDDEN,
        "a player not in the game"
    );

    let creator = send_json_auth(
        app.clone(),
        Method::POST,
        &actions,
        Some(&alice.session_token),
        &resign_engine,
    )
    .await;
    assert_eq!(creator.status(), StatusCode::FORBIDDEN, "even the creator");

    let no_such_seat = send_json_auth(
        app.clone(),
        Method::POST,
        &actions,
        Some(&alice.session_token),
        &GameActionRequest {
            seat_number: 9,
            action: PlayerActionDto::Resign,
        },
    )
    .await;
    assert_eq!(
        no_such_seat.status(),
        StatusCode::FORBIDDEN,
        "a seat that does not exist"
    );

    assert_eq!(
        game_status(app.clone(), &created.id, &alice.session_token).await,
        api::GameStatus::Active,
        "none of those ended the game"
    );

    let preview = format!("/games/{}/preview", created.id);
    let request = PreviewMoveRequest {
        seat_number: 1,
        candidate: one_tile("A", 7, 7, 0),
    };
    let anonymous = send_json_auth(app.clone(), Method::POST, &preview, None, &request).await;
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);
    let other = send_json_auth(
        app.clone(),
        Method::POST,
        &preview,
        Some(&mallory.session_token),
        &request,
    )
    .await;
    assert_eq!(other.status(), StatusCode::FORBIDDEN);
    let creator = send_json_auth(
        app,
        Method::POST,
        &preview,
        Some(&alice.session_token),
        &request,
    )
    .await;
    assert_eq!(creator.status(), StatusCode::FORBIDDEN);
}

/// A move's values are checked where they arrive. Each of these would reach
/// the rules engine as a number it cannot index with, and the answer has to
/// be a refusal, not a crash while the games lock is held.
#[tokio::test]
async fn a_malformed_move_is_refused_at_the_boundary() {
    let app = build_router_for_test().await;
    let (alice, _mallory, created) =
        create_claimed_game_and_second_player(app.clone(), SeatKind::Engine).await;
    send_json_auth(
        app.clone(),
        Method::POST,
        &format!("/games/{}/start", created.id),
        Some(&alice.session_token),
        &StartGameRequest::default(),
    )
    .await;

    let cases: Vec<(&str, MoveCandidateDto)> = vec![
        ("a letter outside the alphabet", one_tile("Ñ", 7, 7, 0)),
        ("an empty letter", one_tile("", 7, 7, 0)),
        ("a start past the right edge", one_tile("A", 15, 7, 0)),
        ("a start past the bottom edge", one_tile("A", 7, 15, 0)),
        ("a start far outside", one_tile("A", 255, 255, 0)),
        ("an offset past the edge", one_tile("A", 7, 7, 14)),
        ("an offset that overflows", one_tile("A", 7, 7, 255)),
        (
            "a blank without a letter",
            MoveCandidateDto {
                start: PositionDto { x: 7, y: 7 },
                direction: DirectionDto::Horizontal,
                tiles: vec![TilePlacementDto {
                    offset: 0,
                    tile: TileDto::Blank { acting_as: None },
                }],
            },
        ),
        (
            "no tiles at all",
            MoveCandidateDto {
                start: PositionDto { x: 7, y: 7 },
                direction: DirectionDto::Horizontal,
                tiles: Vec::new(),
            },
        ),
        (
            "more tiles than a rack holds",
            MoveCandidateDto {
                start: PositionDto { x: 0, y: 7 },
                direction: DirectionDto::Horizontal,
                tiles: (0..8)
                    .map(|offset| TilePlacementDto {
                        offset,
                        tile: TileDto::Letter {
                            letter: "A".to_string(),
                        },
                    })
                    .collect(),
            },
        ),
    ];

    for (why, candidate) in cases {
        let preview = send_json_auth(
            app.clone(),
            Method::POST,
            &format!("/games/{}/preview", created.id),
            Some(&alice.session_token),
            &PreviewMoveRequest {
                seat_number: 0,
                candidate: candidate.clone(),
            },
        )
        .await;
        assert_eq!(
            preview.status(),
            StatusCode::BAD_REQUEST,
            "preview of {why} should be refused as malformed"
        );

        let action = send_json_auth(
            app.clone(),
            Method::POST,
            &format!("/games/{}/actions", created.id),
            Some(&alice.session_token),
            &GameActionRequest {
                seat_number: 0,
                action: PlayerActionDto::Place { candidate },
            },
        )
        .await;
        assert_eq!(
            action.status(),
            StatusCode::BAD_REQUEST,
            "playing {why} should be refused as malformed"
        );
    }

    let exchange = send_json_auth(
        app.clone(),
        Method::POST,
        &format!("/games/{}/actions", created.id),
        Some(&alice.session_token),
        &GameActionRequest {
            seat_number: 0,
            action: PlayerActionDto::Exchange {
                tiles: vec![TileDto::Letter {
                    letter: "Ñ".to_string(),
                }],
            },
        },
    )
    .await;
    assert_eq!(
        exchange.status(),
        StatusCode::BAD_REQUEST,
        "exchanging a letter outside the alphabet is refused too"
    );

    assert_eq!(
        game_status(app, &created.id, &alice.session_token).await,
        api::GameStatus::Active,
        "and the game is still there to be played"
    );
}

/// The address a seat was invited at is the creator's to see, for the
/// re-send button. It is not for the other players, and not for whoever is
/// browsing open seats.
#[tokio::test]
async fn an_invitees_email_is_shown_only_to_the_creator() {
    let app = build_router_for_test().await;
    let alice = register_player(app.clone(), "Alice").await;
    let bob = register_player(app.clone(), "Bob").await;

    let created: GameStateDto = read_json(
        send_json_auth(
            app.clone(),
            Method::POST,
            "/games",
            Some(&alice.session_token),
            &CreateGameRequest {
                seats: vec![
                    CreateSeatRequest {
                        kind: SeatKind::Human,
                        display_name: "Alice".to_string(),
                        engine_id: None,
                        claim: Some(SeatClaim::Creator),
                    },
                    CreateSeatRequest {
                        kind: SeatKind::Human,
                        display_name: "Open seat".to_string(),
                        engine_id: None,
                        claim: Some(SeatClaim::Open),
                    },
                    CreateSeatRequest {
                        kind: SeatKind::Human,
                        display_name: "carol@example.com".to_string(),
                        engine_id: None,
                        claim: Some(SeatClaim::Email {
                            email: "carol@example.com".to_string(),
                        }),
                    },
                ],
                seed: Some(1),
                variant: None,
                language: None,
                board_layout: None,
                move_time_limit_seconds: None,
            },
        )
        .await,
    )
    .await;
    assert!(
        created.participants[2].invited_email.is_some(),
        "the creator sees the address on the game they just made"
    );

    let emails = |participants: &[api::ParticipantDto]| -> Vec<Option<String>> {
        participants
            .iter()
            .map(|p| p.invited_email.clone())
            .collect()
    };

    let bobs_list: Vec<GameSummaryDto> = read_json(
        send_empty_auth(app.clone(), Method::GET, "/games", Some(&bob.session_token)).await,
    )
    .await;
    let open = bobs_list
        .iter()
        .find(|summary| summary.id == created.id)
        .expect("the open seat puts the game on Bob's list");
    assert!(
        emails(&open.participants).iter().all(Option::is_none),
        "browsing an open seat shows no addresses: {:?}",
        emails(&open.participants)
    );

    let accepted = send_empty_auth(
        app.clone(),
        Method::POST,
        &format!(
            "/invitations/{}/accept",
            open.invitation_id.as_deref().expect("an open invitation")
        ),
        Some(&bob.session_token),
    )
    .await;
    assert_eq!(accepted.status(), StatusCode::OK);

    let bobs_view: GameStateDto = read_json(
        send_empty_auth(
            app.clone(),
            Method::GET,
            &format!("/games/{}", created.id),
            Some(&bob.session_token),
        )
        .await,
    )
    .await;
    assert!(
        emails(&bobs_view.participants).iter().all(Option::is_none),
        "a seated opponent sees no addresses: {:?}",
        emails(&bobs_view.participants)
    );

    let bobs_list: Vec<GameSummaryDto> = read_json(
        send_empty_auth(app.clone(), Method::GET, "/games", Some(&bob.session_token)).await,
    )
    .await;
    let seated = bobs_list
        .iter()
        .find(|summary| summary.id == created.id)
        .expect("Bob is seated now");
    assert!(
        emails(&seated.participants).iter().all(Option::is_none),
        "nor in the list once seated: {:?}",
        emails(&seated.participants)
    );

    let alices_view: GameStateDto = read_json(
        send_empty_auth(
            app.clone(),
            Method::GET,
            &format!("/games/{}", created.id),
            Some(&alice.session_token),
        )
        .await,
    )
    .await;
    assert_eq!(
        alices_view.participants[2].invited_email.as_deref(),
        Some("carol@example.com"),
        "the creator still does"
    );
    let alices_list: Vec<GameSummaryDto> =
        read_json(send_empty_auth(app, Method::GET, "/games", Some(&alice.session_token)).await)
            .await;
    let own = alices_list
        .iter()
        .find(|summary| summary.id == created.id)
        .expect("Alice's own game");
    assert_eq!(
        own.participants[2].invited_email.as_deref(),
        Some("carol@example.com"),
        "in the list as well"
    );
}

/// A player's invitations are theirs: no session gets nothing, and another
/// player's session gets a refusal rather than the list.
#[tokio::test]
async fn a_players_invitations_need_that_players_sign_in() {
    let app = build_router_for_test().await;
    let alice = register_player(app.clone(), "Alice").await;
    let bob = register_player(app.clone(), "Bob").await;
    let path = format!("/players/{}/invitations", alice.player_id);

    let anonymous = send_empty(app.clone(), Method::GET, &path).await;
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);

    let other = send_empty_auth(app.clone(), Method::GET, &path, Some(&bob.session_token)).await;
    assert_eq!(other.status(), StatusCode::FORBIDDEN);

    let own = send_empty_auth(app, Method::GET, &path, Some(&alice.session_token)).await;
    assert_eq!(own.status(), StatusCode::OK);
}
