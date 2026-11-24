//! The router as a whole: every route declares who may call it
//! (`routes::Access`), and these two tests hold the list to that.
//!
//! - `every_handler_meets_the_level_its_route_declares` walks the list and
//!   sends each route the requests its level says must be refused.
//! - `the_route_list_and_the_api_schema_agree` compares the list with
//!   docs/4.4.3's route tables, both ways.
//!
//! Neither names a route, so a new one is held to its level without anybody
//! remembering to. A route the walk has no request for fails the test.

use std::collections::BTreeMap;
use std::io::{Read, Write};

use super::routes::{self, Access, Limit, Route, Verb};
use super::*;
use crate::app::tests::{
    create_test_state, create_two_human_game_waiting, loopback_peer, register_player, remote_peer,
    send_admin, test_database_url,
};
use api::{
    CreateSeatRequest, DirectionDto, MoveCandidateDto, PlayerActionDto, PositionDto, SeatClaim,
    SeatKind, TileDto, TilePlacementDto,
};
use axum::body::Body;
use axum::http::{Method, Request};
use tower::util::ServiceExt;

const PASSWORD: &str = "correct horse battery staple";

/// A waiting two-seat game (Alice created it and holds seat 0, Bob holds
/// seat 1: the creator, and a seated player who is not) and Mallory, who is signed in and has nothing to do with it.
struct World {
    state: AppState,
    game_id: String,
    alice: PlayerSessionDto,
    bob: PlayerSessionDto,
    mallory: PlayerSessionDto,
    registered: std::sync::atomic::AtomicUsize,
}

impl World {
    async fn new() -> Self {
        let state = create_test_state(&test_database_url()).await;
        let game = create_two_human_game_waiting(build_router(state.clone())).await;
        let mallory = register_player(build_router(state.clone()), "Mallory").await;
        World {
            state,
            game_id: game.game.id,
            alice: game.alice,
            bob: game.bob,
            mallory,
            registered: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// A router of its own for every request, so no request's effects reach
    /// the next. The rate limiters are off under `cfg(test)`, so nothing here
    /// tests which tier a route sits in.
    fn router(&self) -> Router {
        build_router(self.state.clone())
    }

    fn uri(&self, route: &Route) -> String {
        let uri = route
            .path
            .replace("{game_id}", &self.game_id)
            .replace("{seat_number}", "1")
            .replace("{player_id}", &self.alice.player_id)
            .replace("{engine_id}", "greedy-v1")
            .replace("{name}", "sowpods")
            .replace("{invitation_id}", "no-such-invitation");
        assert!(
            !uri.contains('{'),
            "{}: the walk does not know a path parameter",
            route.path
        );
        // `q` is required.
        if route.path == "/players/search" {
            return format!("{uri}?q=al");
        }
        uri
    }

    /// The body each route needs to get past its extractors and reach its
    /// handler. A route with no entry fails the test: the walk cannot
    /// exercise it, and a route unexercised is a route unchecked.
    fn body(&self, route: &Route, token: Option<&str>) -> Option<serde_json::Value> {
        use serde_json::{json, to_value};
        let engine_seat = CreateSeatRequest {
            kind: SeatKind::Engine,
            display_name: "Greedy".to_string(),
            engine_id: Some("greedy-v1".to_string()),
            claim: None,
        };
        let one_tile = MoveCandidateDto {
            start: PositionDto { x: 7, y: 7 },
            direction: DirectionDto::Horizontal,
            tiles: vec![TilePlacementDto {
                offset: 0,
                tile: TileDto::Letter {
                    letter: "A".to_string(),
                },
            }],
        };
        match (route.verb, route.path) {
            // Nothing to send.
            (Verb::Get, _) => None,
            (
                Verb::Post,
                "/auth/logout"
                | "/games/{game_id}/abort"
                | "/games/{game_id}/remove"
                | "/games/{game_id}/suggest"
                | "/games/{game_id}/seats/{seat_number}/remove"
                | "/games/{game_id}/seats/{seat_number}/withdraw"
                | "/games/{game_id}/seats/{seat_number}/force-resign"
                | "/invitations/{invitation_id}/accept"
                | "/invitations/{invitation_id}/reject",
            ) => None,
            (Verb::Post, path) => match path {
                "/auth/register" => {
                    let n = self
                        .registered
                        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    Some(json!({
                        "display_name": format!("Walker{n}"),
                        "email": format!("walker{n}@example.com"),
                        "password": PASSWORD,
                        "stay_logged_in": false,
                    }))
                }
                "/auth/login" => Some(json!({
                    "display_name": "Alice",
                    "password": PASSWORD,
                    "stay_logged_in": false,
                })),
                "/auth/forgot-password" => Some(json!({"email": "nobody@example.com"})),
                "/auth/reset-password" => Some(json!({
                    "token": "no-such-token",
                    "new_password": "a new password",
                })),
                // The one route that takes its session from the body.
                "/auth/validate" => Some(json!({"session_token": token.unwrap_or("")})),
                "/auth/change-password" => Some(json!({
                    "current_password": PASSWORD,
                    "new_password": "a new password",
                })),
                "/auth/update-details" => Some(json!({"display_name": "Alicia"})),
                "/games" => Some(
                    to_value(CreateGameRequest {
                        seats: vec![
                            CreateSeatRequest {
                                kind: SeatKind::Human,
                                display_name: "Walker".to_string(),
                                engine_id: None,
                                claim: Some(SeatClaim::Creator),
                            },
                            engine_seat,
                        ],
                        seed: Some(1),
                        variant: None,
                        language: None,
                        board_layout: None,
                        move_time_limit_seconds: None,
                    })
                    .unwrap(),
                ),
                "/games/{game_id}/start" => Some(to_value(StartGameRequest::default()).unwrap()),
                "/games/{game_id}/reorder-seats" => Some(
                    to_value(SwapSeatsRequest {
                        seat_a: 0,
                        seat_b: 1,
                    })
                    .unwrap(),
                ),
                "/games/{game_id}/seats" => Some(to_value(engine_seat).unwrap()),
                "/games/{game_id}/actions" => Some(
                    to_value(GameActionRequest {
                        seat_number: 1,
                        action: PlayerActionDto::Pass,
                    })
                    .unwrap(),
                ),
                "/games/{game_id}/chat" => Some(
                    to_value(PostChatMessageRequest {
                        body: "hello".to_string(),
                    })
                    .unwrap(),
                ),
                "/games/{game_id}/preview" => Some(
                    to_value(PreviewMoveRequest {
                        seat_number: 1,
                        candidate: one_tile,
                    })
                    .unwrap(),
                ),
                "/games/{game_id}/invite" => Some(
                    to_value(InvitePlayerRequest {
                        invited_display_name: Some("Bob".to_string()),
                        invited_email: None,
                        seat_number: 1,
                    })
                    .unwrap(),
                ),
                other => {
                    panic!("{other}: the walk has no request for this route, so it cannot check it")
                }
            },
            (verb, path) => panic!("{verb:?} {path}: the walk has no request for this route"),
        }
    }

    async fn send(&self, route: &Route, token: Option<&str>) -> u16 {
        let method = match route.verb {
            Verb::Get => Method::GET,
            Verb::Post => Method::POST,
            Verb::Delete => Method::DELETE,
        };
        let uri = self.uri(route);
        // A WebSocket handshake cannot be made by `oneshot`: the extractor
        // wants a real connection's upgrade machinery.
        if route.path == routes::EVENTS_PATH {
            let uri = match token {
                Some(token) => format!("{uri}?token={token}"),
                None => uri,
            };
            return self.websocket_status(&uri).await;
        }
        let mut request = Request::builder().method(method).uri(uri);
        if let Some(token) = token {
            request = request.header("authorization", format!("Bearer {token}"));
        }
        let request = match self.body(route, token) {
            Some(body) => request
                .header("content-type", "application/json")
                .body(Body::from(body.to_string())),
            None => request.body(Body::empty()),
        }
        .expect("request should build");
        self.router()
            .oneshot(request)
            .await
            .expect("request should succeed")
            .status()
            .as_u16()
    }

    /// The status line a real server answers a WebSocket handshake with.
    async fn websocket_status(&self, uri: &str) -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("a local port");
        let address = listener.local_addr().expect("its address");
        let app = self.router();
        let server = tokio::spawn(async move {
            let _ = axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await;
        });
        let status = tokio::task::spawn_blocking({
            let uri = uri.to_string();
            move || {
                let mut stream = std::net::TcpStream::connect(address).expect("connects");
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                    .expect("timeout");
                write!(
                    stream,
                    "GET {uri} HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n\
                     Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\n\
                     Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
                )
                .expect("writes");
                let mut line = [0u8; 12];
                stream.read_exact(&mut line).expect("a status line");
                String::from_utf8_lossy(&line[9..12])
                    .parse::<u16>()
                    .expect("a status code")
            }
        })
        .await
        .expect("the client thread finishes");
        server.abort();
        status
    }
}

fn method_of(verb: Verb) -> Method {
    match verb {
        Verb::Get => Method::GET,
        Verb::Post => Method::POST,
        Verb::Delete => Method::DELETE,
    }
}

/// What a request must get: exactly this status, or anything but 401 and 403
/// (a permitted caller may meet any other refusal, such as a 400 for a game
/// in the wrong state, but not a refusal of who they are).
#[derive(Clone, Copy)]
enum Expect {
    Status(u16),
    Admitted,
}

/// A fresh world for every route, so one route's changes to the game (an
/// abort, a removed seat) cannot change what the next is asked.
#[tokio::test(flavor = "multi_thread")]
async fn every_handler_meets_the_level_its_route_declares() {
    let mut failures = Vec::new();
    let mut exercised = 0;

    for route in routes::all() {
        let world = World::new().await;
        let name = format!("{:?} {} ({:?})", route.verb, route.path, route.access);
        let own = world.alice.session_token.clone();
        let bob = world.bob.session_token.clone();
        let mallory = world.mallory.session_token.clone();
        let unknown = "not-a-token".to_string();
        let mut cases: Vec<(&str, Option<&str>, Expect)> = Vec::new();
        match route.access {
            Access::Public => {
                cases.push(("no token", None, Expect::Admitted));
                cases.push(("an unknown token", Some(&unknown), Expect::Admitted));
            }
            Access::Session => {
                cases.push(("no token", None, Expect::Status(401)));
                cases.push(("an unknown token", Some(&unknown), Expect::Status(401)));
                cases.push(("a valid session", Some(&mallory), Expect::Admitted));
            }
            Access::Owner => {
                cases.push(("no token", None, Expect::Status(401)));
                cases.push(("another player", Some(&mallory), Expect::Status(403)));
                cases.push(("the named player", Some(&own), Expect::Admitted));
            }
            Access::Game => {
                cases.push(("no token", None, Expect::Status(401)));
                cases.push(("an unknown token", Some(&unknown), Expect::Status(401)));
                cases.push((
                    "a player outside the game",
                    Some(&mallory),
                    Expect::Status(403),
                ));
                cases.push(("a seated player", Some(&bob), Expect::Admitted));
            }
            Access::Creator => {
                cases.push(("no token", None, Expect::Status(401)));
                cases.push(("an unknown token", Some(&unknown), Expect::Status(401)));
                cases.push((
                    "a player outside the game",
                    Some(&mallory),
                    Expect::Status(403),
                ));
                cases.push((
                    "a seated player who is not the creator",
                    Some(&bob),
                    Expect::Status(403),
                ));
                cases.push(("the creator", Some(&own), Expect::Admitted));
            }
            Access::Loopback => {
                let uri = world.uri(&route);
                let body = (route.path == "/admin/users/{player_id}/reset-password")
                    .then(|| serde_json::json!({"new_password": "a new password"}));
                for (case, peer, expect) in [
                    ("a remote address", remote_peer(), Expect::Status(403)),
                    ("the loopback address", loopback_peer(), Expect::Admitted),
                ] {
                    let got = send_admin(
                        world.router(),
                        method_of(route.verb),
                        &uri,
                        peer,
                        body.as_ref(),
                    )
                    .await
                    .status()
                    .as_u16();
                    exercised += 1;
                    check(&mut failures, &name, case, got, expect);
                }
                continue;
            }
        }
        for (case, token, expect) in cases {
            let got = world.send(&route, token).await;
            exercised += 1;
            check(&mut failures, &name, case, got, expect);
        }
    }

    assert!(exercised > 0);
    assert!(
        failures.is_empty(),
        "{} case(s) where a handler does not meet its level:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

fn check(failures: &mut Vec<String>, name: &str, case: &str, got: u16, expect: Expect) {
    match expect {
        Expect::Status(want) if got != want => {
            failures.push(format!("{name}: with {case} answered {got}, not {want}"))
        }
        Expect::Admitted if got == 401 || got == 403 => failures.push(format!(
            "{name}: with {case} answered {got}, which a permitted caller never gets"
        )),
        _ => {}
    }
}

/// Lists, tiers and spellings that must hold whatever a row says.
#[test]
fn the_route_list_is_consistent() {
    let mut seen = std::collections::BTreeSet::new();
    for route in routes::all() {
        assert!(
            seen.insert((verb_name(route.verb), route.path)),
            "{:?} {} is listed twice",
            route.verb,
            route.path
        );
        assert_eq!(
            route.access == Access::Loopback,
            route.path.starts_with("/admin/"),
            "{}: /admin/* is Loopback and nothing else is",
            route.path
        );
        if route.access == Access::Loopback {
            assert_eq!(
                route.limit,
                Limit::Unlimited,
                "{}: admin is unlimited",
                route.path
            );
        }
        if route.access == Access::Owner {
            assert!(
                route.path.contains("{player_id}"),
                "{}: an Owner route names the player in its path",
                route.path
            );
        }
    }
}

/// `{id}` in the schema and `{game_id}` in the code name the same thing, so
/// compare with the names taken out.
fn unnamed(path: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for c in path.chars() {
        match c {
            '{' => {
                inside = true;
                out.push_str("{}");
            }
            '}' => inside = false,
            _ if !inside => out.push(c),
            _ => {}
        }
    }
    out
}

/// The route rows of 4.4.3's tables: method, path, level.
fn documented_routes(doc: &str) -> BTreeMap<(String, String), String> {
    let mut rows = BTreeMap::new();
    for line in doc.lines() {
        let cells: Vec<&str> = line.split('|').map(str::trim).collect();
        if cells.len() < 5 || !matches!(cells[1], "GET" | "POST" | "DELETE") {
            continue;
        }
        let path = cells[2].trim_matches('`');
        let path = path.split('?').next().unwrap_or(path);
        let level = cells[3].split_whitespace().next().unwrap_or("");
        let key = (cells[1].to_string(), unnamed(path));
        assert!(
            rows.insert(key, level.to_string()).is_none(),
            "4.4.3 lists {} {path} twice",
            cells[1]
        );
    }
    rows
}

fn verb_name(verb: Verb) -> &'static str {
    match verb {
        Verb::Get => "GET",
        Verb::Post => "POST",
        Verb::Delete => "DELETE",
    }
}

fn compare_with_schema(doc: &str, list: &[Route]) -> Vec<String> {
    let documented = documented_routes(doc);
    let mut problems = Vec::new();
    let mut listed = std::collections::BTreeSet::new();
    for route in list {
        let key = (verb_name(route.verb).to_string(), unnamed(route.path));
        listed.insert(key.clone());
        match documented.get(&key) {
            None => problems.push(format!(
                "{} {} is a route with no row in 4.4.3",
                key.0, route.path
            )),
            Some(level) if *level != format!("{:?}", route.access) => problems.push(format!(
                "{} {}: the code says {:?}, 4.4.3 says {level}",
                key.0, route.path, route.access
            )),
            Some(_) => {}
        }
    }
    for (method, path) in documented.keys() {
        if !listed.contains(&(method.clone(), path.clone())) {
            problems.push(format!("{method} {path} is a row in 4.4.3 with no route"));
        }
    }
    problems
}

const API_SCHEMA: &str = include_str!("../../../../docs/4.4.3-api-schema.md");

#[test]
fn the_route_list_and_the_api_schema_agree() {
    let problems = compare_with_schema(API_SCHEMA, &routes::all());
    assert!(
        problems.is_empty(),
        "the route list and docs/4.4.3 differ:\n{}",
        problems.join("\n")
    );
}
