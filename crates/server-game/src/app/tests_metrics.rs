//! The symptom counters (#402 WP B, `delphside/tile-lite-elite#609`): what the
//! counting layer adds, where, and what `GET /admin/metrics` answers.
//!
//! The conditions come from the design's *Test approach*, T1 to T14, each named
//! in the doc comment of the test that holds it. T3's throttle half is in
//! `throttle.rs`, beside the limiter it builds, and T13 and T14's are
//! `scripts/tests/test_check_api_errors.py` and the admin CLI's own tests.
//!
//! **Each test reads the counters before and after, and says which moved**, so
//! no test depends on what another did: every state has counters of its own.

use super::*;
use crate::app::metrics::{LATENCY_BOUNDS_MS, bucket_for};
use crate::app::tests::{
    create_test_state, create_two_human_game_waiting, loopback_peer, read_json, register_player,
    remote_peer, send_admin, test_database_url,
};
use api::{AdminMetricsDto, ErrorType};
use axum::body::Body;
use axum::http::{Method, Request};
use serde_json::Value;
use std::collections::BTreeMap;
use tower::util::ServiceExt;

/// A router with routes that answer what a test asks for, behind the same
/// layers production has, and the state whose counters it fills.
async fn counted() -> (Router, AppState) {
    let state = create_test_state(&test_database_url()).await;
    let extra = Router::new()
        // Any status, answered bare: the layers above build what a caller sees.
        .route(
            "/__status/{code}",
            get(|Path(code): Path<u16>| async move { StatusCode::from_u16(code).unwrap() }),
        )
        // Any reason, answered as a handler does: through `ApiProblem`.
        .route(
            "/__reason/{code}",
            get(|Path(code): Path<String>| async move {
                let reason: Reason =
                    serde_json::from_value(Value::String(code)).expect("a reason's code");
                Err::<(), _>(ApiProblem::new(reason, "A test's refusal."))
            }),
        )
        .route("/__ok", get(|| async { "fine" }))
        .route("/__panic", get(|| async { panic!("a handler's defect") }))
        .route(
            "/__busy_database",
            get(|| async { Err::<(), _>(ApiProblem::from_sqlx(sqlx::Error::PoolTimedOut)) }),
        )
        .route(
            "/__json",
            post(|Json(_): Json<api::CreateSeatRequest>| async { "ok" }),
        )
        // An error that claims to be a problem without passing through `render`.
        .route(
            "/__unclassified",
            get(|| async {
                (
                    StatusCode::BAD_REQUEST,
                    [(axum::http::header::CONTENT_TYPE, PROBLEM_JSON)],
                    "{}",
                )
            }),
        )
        // The one failure inside the error path.
        .route(
            "/__unserialisable",
            get(|| async {
                let failure = serde_json::from_str::<u8>("not a number").unwrap_err();
                ApiProblem::new(Reason::GameNotFound, "Game not found").render(|_| Err(failure))
            }),
        );
    (build_router_with(state.clone(), extra), state)
}

async fn send(app: &Router, method: Method, uri: &str) -> StatusCode {
    let request = Request::builder()
        .method(method)
        .uri(uri)
        .body(Body::empty())
        .expect("request should build");
    app.clone()
        .oneshot(request)
        .await
        .expect("the router answers")
        .status()
}

async fn get_status(app: &Router, uri: &str) -> StatusCode {
    send(app, Method::GET, uri).await
}

/// Every counter, named, in the order of the DTO. The latency buckets are
/// `latency.0` to `latency.8`.
fn flat(dto: &AdminMetricsDto) -> BTreeMap<String, u64> {
    let mut all = BTreeMap::new();
    let mut put = |name: &str, value: u64| {
        all.insert(name.to_string(), value);
    };
    put("responses.informational", dto.responses.informational);
    put("responses.success", dto.responses.success);
    put("responses.redirection", dto.responses.redirection);
    put("responses.client_error", dto.responses.client_error);
    put("responses.server_error", dto.responses.server_error);
    put("errors.business", dto.errors.business);
    put("errors.technical", dto.errors.technical);
    put("errors.unexpected", dto.errors.unexpected);
    put("errors.unclassified", dto.errors.unclassified);
    put("too_many_requests", dto.too_many_requests);
    put("service_unavailable", dto.service_unavailable);
    put("panics_caught", dto.panics_caught);
    put(
        "websocket_handshake_failures",
        dto.websocket_handshake_failures,
    );
    for (index, count) in dto.latency.counts.iter().enumerate() {
        put(&format!("latency.{index}"), *count);
    }
    all
}

/// What changed between two reads, apart from the latency buckets, as name to
/// amount. A counter that fell fails here: they only grow.
fn moved(before: &AdminMetricsDto, after: &AdminMetricsDto) -> BTreeMap<String, u64> {
    let before = flat(before);
    flat(after)
        .into_iter()
        .filter(|(name, _)| !name.starts_with("latency."))
        .filter_map(|(name, now)| {
            let was = before[&name];
            assert!(now >= was, "{name} fell from {was} to {now}");
            (now > was).then(|| (name, now - was))
        })
        .collect()
}

fn latency_total(dto: &AdminMetricsDto) -> u64 {
    dto.latency.counts.iter().sum()
}

fn response_total(dto: &AdminMetricsDto) -> u64 {
    let r = &dto.responses;
    r.informational + r.success + r.redirection + r.client_error + r.server_error
}

fn error_total(dto: &AdminMetricsDto) -> u64 {
    let e = &dto.errors;
    e.business + e.technical + e.unexpected + e.unclassified
}

fn expect(pairs: &[(&str, u64)]) -> BTreeMap<String, u64> {
    pairs
        .iter()
        .map(|(name, amount)| (name.to_string(), *amount))
        .collect()
}

/// The `errors` field a type is counted in.
fn error_field(kind: ErrorType) -> &'static str {
    match kind {
        ErrorType::Business => "errors.business",
        ErrorType::Technical => "errors.technical",
        _ => "errors.unexpected",
    }
}

/// T1: every response is in exactly one class. A 200, 404, 500, 101 and 301,
/// and a CORS preflight the CORS layer answers, each move exactly the one field
/// of `responses`, by one, and the fields sum to the requests made.
#[tokio::test]
async fn t1_every_response_is_in_exactly_one_class() {
    let (app, state) = counted().await;
    let mut made = 0;
    for (uri, field) in [
        ("/__status/200", "responses.success"),
        ("/no/such/route", "responses.client_error"),
        ("/__status/500", "responses.server_error"),
        ("/__status/101", "responses.informational"),
        ("/__status/301", "responses.redirection"),
    ] {
        let before = state.metrics.snapshot();
        get_status(&app, uri).await;
        made += 1;
        let after = state.metrics.snapshot();
        let changed = moved(&before, &after);
        let in_responses: Vec<_> = changed
            .iter()
            .filter(|(name, _)| name.starts_with("responses."))
            .collect();
        assert_eq!(in_responses.len(), 1, "{uri}: {changed:?}");
        assert_eq!(changed[field], 1, "{uri}: {changed:?}");
        assert_eq!(response_total(&after), made, "{uri}");
    }

    // A preflight, answered by the CORS layer without reaching the route.
    let before = state.metrics.snapshot();
    let preflight = Request::builder()
        .method(Method::OPTIONS)
        .uri("/__ok")
        .header("origin", "https://example.com")
        .header("access-control-request-method", "GET")
        .body(Body::empty())
        .unwrap();
    let answered = app.clone().oneshot(preflight).await.unwrap();
    assert!(
        answered
            .headers()
            .contains_key("access-control-allow-origin")
    );
    let after = state.metrics.snapshot();
    let class = if answered.status().is_success() {
        "responses.success"
    } else {
        panic!("a preflight answered {}", answered.status());
    };
    assert_eq!(moved(&before, &after)[class], 1);
    assert_eq!(response_total(&after), made + 1);
    assert_eq!(latency_total(&after), response_total(&after));
}

/// T2: the reason decides the type. An error built with each variant of
/// `Reason` moves exactly the field of `errors` its `error_type()` names, and
/// the class its status names, and no other; a new reason is covered by
/// `Reason::ALL`.
#[tokio::test]
async fn t2_the_reason_decides_the_type() {
    let (app, state) = counted().await;
    for &reason in Reason::ALL {
        let code = serde_json::to_value(reason).unwrap();
        let code = code.as_str().unwrap();
        let before = state.metrics.snapshot();
        let status = get_status(&app, &format!("/__reason/{code}")).await;
        let after = state.metrics.snapshot();
        assert_eq!(status.as_u16(), reason.status(), "{code}");

        let class = if status.is_client_error() {
            "responses.client_error"
        } else {
            "responses.server_error"
        };
        let mut want = expect(&[(class, 1), (error_field(reason.error_type()), 1)]);
        match reason.status() {
            429 => want.insert("too_many_requests".into(), 1),
            503 => want.insert("service_unavailable".into(), 1),
            _ => None,
        };
        assert_eq!(moved(&before, &after), want, "{code}");
    }
}

/// T3: an error a layer builds is classified as one a handler builds: a busy
/// database's 503, an axum 415 and a panic's 500 each move `errors` by their
/// reason's type with `unclassified` at zero; a 4xx built outside `render`
/// with a problem content type and no reason moves `unclassified` and nothing
/// else in `errors`; a body that fails to serialise counts as `Internal`. The
/// limiter's own 429 and 503 are `throttle.rs`'s half of T3.
#[tokio::test]
async fn t3_an_error_a_layer_builds_is_classified_as_a_handlers_is() {
    let (app, state) = counted().await;

    let before = state.metrics.snapshot();
    assert_eq!(get_status(&app, "/__busy_database").await.as_u16(), 503);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[
            ("responses.server_error", 1),
            ("errors.technical", 1),
            ("service_unavailable", 1)
        ])
    );

    let before = state.metrics.snapshot();
    assert_eq!(send(&app, Method::POST, "/__json").await.as_u16(), 415);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[("responses.client_error", 1), ("errors.business", 1)])
    );

    let before = state.metrics.snapshot();
    assert_eq!(get_status(&app, "/__panic").await.as_u16(), 500);
    let after = state.metrics.snapshot();
    assert_eq!(after.errors.unclassified, 0);
    assert_eq!(after.errors.unexpected, before.errors.unexpected + 1);

    let before = state.metrics.snapshot();
    assert_eq!(get_status(&app, "/__unclassified").await.as_u16(), 400);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[("responses.client_error", 1), ("errors.unclassified", 1)])
    );
    assert_eq!(latency_total(&after), latency_total(&before) + 1);

    // The reason is `GameNotFound`, a 404 and business, until the body fails
    // to serialise: then the answer is the fixed 500, and counted as it is.
    let before = state.metrics.snapshot();
    assert_eq!(get_status(&app, "/__unserialisable").await.as_u16(), 500);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[("responses.server_error", 1), ("errors.unexpected", 1)])
    );
}

/// T4: 429 and 503 are counted apart. A 429 moves `too_many_requests` only, a
/// 503 `service_unavailable` only, a 500 neither.
#[tokio::test]
async fn t4_429_and_503_are_counted_apart() {
    let (app, state) = counted().await;
    for (reason, own, other) in [
        (
            "TOO_MANY_REQUESTS",
            "too_many_requests",
            "service_unavailable",
        ),
        ("SERVICE_BUSY", "service_unavailable", "too_many_requests"),
        ("INTERNAL", "", ""),
    ] {
        let before = flat(&state.metrics.snapshot());
        get_status(&app, &format!("/__reason/{reason}")).await;
        let after = flat(&state.metrics.snapshot());
        for name in ["too_many_requests", "service_unavailable"] {
            let step = after[name] - before[name];
            let want = u64::from(name == own);
            assert_eq!(step, want, "{reason}: {name} (not {other})");
        }
    }
}

/// T5: a panic is counted once as a panic and once as an `unexpected` 500, and
/// the answer is still the 500 with the body.
#[tokio::test]
async fn t5_a_panic_is_counted_as_a_panic_and_as_an_unexpected_500() {
    let (app, state) = counted().await;
    let before = state.metrics.snapshot();
    let request = Request::builder()
        .uri("/__panic")
        .body(Body::empty())
        .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
    let body: api::ApiError = read_json(response).await;
    assert_eq!(body.reason, Some(Reason::Internal));
    assert_eq!(body.detail, INTERNAL_MESSAGE);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[
            ("panics_caught", 1),
            ("responses.server_error", 1),
            ("errors.unexpected", 1)
        ])
    );
}

/// What a raw client gets back from the server's handshake: the status, and
/// the stream kept open so a 101 stays upgraded while the test reads.
async fn handshake(addr: SocketAddr, path: &str, upgrade: bool) -> (u16, tokio::net::TcpStream) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut stream = tokio::net::TcpStream::connect(addr).await.unwrap();
    let headers = if upgrade {
        "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    } else {
        ""
    };
    let request = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\n{headers}\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut line = [0u8; 12];
    stream.read_exact(&mut line).await.unwrap();
    let status = String::from_utf8_lossy(&line[9..12]).parse().unwrap();
    (status, stream)
}

/// T6: a handshake failure is a non-upgraded request to the events route, and
/// nothing else. No token, a token with no session, a signed-in player not in
/// the game, an unknown game and a request without upgrade headers each move
/// `websocket_handshake_failures`; a successful upgrade and the same refusals
/// on another route do not. It also proves the layer sees `MatchedPath`.
#[tokio::test(flavor = "multi_thread")]
async fn t6_a_handshake_failure_is_a_refused_request_to_the_events_route() {
    let state = create_test_state(&test_database_url()).await;
    let app = build_router(state.clone());
    let game = create_two_human_game_waiting(app.clone()).await;
    let stranger = register_player(app.clone(), "Stranger").await;
    let gid = game.game.id.clone();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let served = app.clone();
    tokio::spawn(async move {
        let _ = axum::serve(
            listener,
            served.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;
    });

    let refused = [
        (format!("/games/{gid}/events"), true, 401),
        (format!("/games/{gid}/events?token=dead"), true, 401),
        (
            format!("/games/{gid}/events?token={}", stranger.session_token),
            true,
            403,
        ),
        (
            format!("/games/nope/events?token={}", game.alice.session_token),
            true,
            404,
        ),
        (
            format!("/games/{gid}/events?token={}", game.alice.session_token),
            false,
            400,
        ),
    ];
    for (path, upgrade, status) in refused {
        let before = state.metrics.snapshot();
        let (got, _stream) = handshake(addr, &path, upgrade).await;
        assert_eq!(got, status, "{path}");
        let after = state.metrics.snapshot();
        assert_eq!(
            after.websocket_handshake_failures,
            before.websocket_handshake_failures + 1,
            "{path}"
        );
    }

    // A successful upgrade is a 101 and not a failure.
    let before = state.metrics.snapshot();
    let (got, _stream) = handshake(
        addr,
        &format!("/games/{gid}/events?token={}", game.bob.session_token),
        true,
    )
    .await;
    assert_eq!(got, 101);
    let after = state.metrics.snapshot();
    assert_eq!(
        moved(&before, &after),
        expect(&[("responses.informational", 1)])
    );

    // The same refusals on another route are not handshakes.
    let before = state.metrics.snapshot();
    for uri in [
        format!("/games/{gid}"),
        format!("/games/{gid}?token=dead"),
        "/games/nope".to_string(),
    ] {
        assert!(get_status(&app, &uri).await.is_client_error(), "{uri}");
    }
    let after = state.metrics.snapshot();
    assert_eq!(
        after.websocket_handshake_failures,
        before.websocket_handshake_failures
    );
    assert_eq!(
        after.responses.client_error,
        before.responses.client_error + 3
    );
}

/// T7: a latency falls in the bucket whose bound it first does not exceed,
/// at each bound one microsecond under, on and one over it, and at zero and an
/// hour; `counts` is one longer than `bounds_ms` and the bounds ascend.
#[test]
fn t7_a_latency_falls_in_the_first_bucket_it_does_not_exceed() {
    use std::time::Duration;
    assert_eq!(
        LATENCY_BOUNDS_MS,
        [10, 50, 100, 250, 500, 1_000, 5_000, 60_000]
    );
    let micro = Duration::from_micros(1);
    for (index, &bound) in LATENCY_BOUNDS_MS.iter().enumerate() {
        let at = Duration::from_millis(bound);
        assert_eq!(bucket_for(at - micro), index, "1 us under {bound} ms");
        assert_eq!(bucket_for(at), index, "on {bound} ms");
        assert_eq!(bucket_for(at + micro), index + 1, "1 us over {bound} ms");
    }
    assert_eq!(bucket_for(Duration::ZERO), 0);
    assert_eq!(
        bucket_for(Duration::from_secs(3600)),
        LATENCY_BOUNDS_MS.len()
    );

    let dto = crate::app::metrics::Metrics::new().snapshot();
    assert_eq!(dto.latency.counts.len(), dto.latency.bounds_ms.len() + 1);
    assert!(
        dto.latency
            .bounds_ms
            .windows(2)
            .all(|pair| pair[0] < pair[1])
    );
}

/// T8: counting is exact under concurrency. 200 requests from 50 tasks at once
/// leave the sum of `responses` and the sum of `counts` at 200, and
/// `client_error` plus `server_error` equal to the sum of `errors`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn t8_counting_is_exact_under_concurrency() {
    let (app, state) = counted().await;
    let mut tasks = Vec::new();
    for task in 0..50 {
        let app = app.clone();
        tasks.push(tokio::spawn(async move {
            for round in 0..4 {
                let uri = match (task + round) % 4 {
                    0 => "/__ok",
                    1 => "/no/such/route",
                    2 => "/__reason/SERVICE_BUSY",
                    _ => "/__reason/NOT_YOUR_TURN",
                };
                get_status(&app, uri).await;
            }
        }));
    }
    for task in tasks {
        task.await.unwrap();
    }
    let dto = state.metrics.snapshot();
    assert_eq!(response_total(&dto), 200);
    assert_eq!(latency_total(&dto), 200);
    assert_eq!(
        dto.responses.client_error + dto.responses.server_error,
        error_total(&dto)
    );
    assert_eq!(dto.responses.success, 50);
    assert_eq!(dto.service_unavailable, 50);
}

/// T9: the counters are cumulative and never fall. Two reads with requests
/// between them show every field equal or greater, and `started_at` the same.
#[tokio::test]
async fn t9_the_counters_are_cumulative() {
    let (app, state) = counted().await;
    get_status(&app, "/__ok").await;
    get_status(&app, "/no/such/route").await;
    let first = state.metrics.snapshot();
    get_status(&app, "/__reason/INTERNAL").await;
    get_status(&app, "/__ok").await;
    let second = state.metrics.snapshot();
    assert_eq!(first.started_at, second.started_at);
    // `moved` fails on any field that fell.
    let grown = moved(&first, &second);
    assert!(!grown.is_empty());
    assert_eq!(response_total(&second), response_total(&first) + 2);
}

/// T10: a new state starts every counter at zero, with `started_at` the time it
/// was made, so two states made a second apart report different values.
#[tokio::test]
async fn t10_a_new_state_starts_at_zero() {
    let before = now_unix_seconds();
    let first = create_test_state(&test_database_url()).await;
    let one = first.metrics.snapshot();
    assert!(one.started_at >= before && one.started_at <= now_unix_seconds());
    assert!(flat(&one).values().all(|count| *count == 0), "{one:?}");

    get_status(&build_router(first.clone()), "/health").await;
    assert_eq!(response_total(&first.metrics.snapshot()), 1);

    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let second = create_test_state(&test_database_url()).await;
    let two = second.metrics.snapshot();
    assert!(two.started_at > one.started_at, "{one:?} {two:?}");
    assert!(flat(&two).values().all(|count| *count == 0), "{two:?}");
}

/// T11: the endpoint is loopback only. A caller whose address is not loopback
/// is answered `ADMIN_LOOPBACK_ONLY` 403 and no counters; one that is, the
/// object. `tests_routes.rs` holds the row to 4.4.3's in both directions.
#[tokio::test]
async fn t11_the_endpoint_is_loopback_only() {
    let (app, _state) = counted().await;
    let refused = send_admin::<()>(
        app.clone(),
        Method::GET,
        "/admin/metrics",
        remote_peer(),
        None,
    )
    .await;
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);
    let body: Value = read_json(refused).await;
    assert_eq!(body["reason"], "ADMIN_LOOPBACK_ONLY");
    assert!(body.get("responses").is_none() && body.get("latency").is_none());

    let answered =
        send_admin::<()>(app, Method::GET, "/admin/metrics", loopback_peer(), None).await;
    assert_eq!(answered.status(), StatusCode::OK);
    let dto: AdminMetricsDto = read_json(answered).await;
    // The refusal above was counted before this read; this request is not yet.
    assert_eq!(dto.responses.client_error, 1);
    assert_eq!(dto.errors.business, 1);
}

/// T12: the body is the DTO and holds only counts and bounds. The answer
/// deserialises to `AdminMetricsDto`, the DTO round-trips through
/// `serde_json`, and no value in the JSON is a string.
#[tokio::test]
async fn t12_the_body_is_the_dto_and_holds_only_numbers() {
    let (app, state) = counted().await;
    get_status(&app, "/__ok").await;
    let answered =
        send_admin::<()>(app, Method::GET, "/admin/metrics", loopback_peer(), None).await;
    let raw: Value = read_json(answered).await;
    let dto: AdminMetricsDto = serde_json::from_value(raw.clone()).expect("the DTO");
    assert_eq!(dto.responses.success, 1);
    assert_eq!(dto.latency.bounds_ms, LATENCY_BOUNDS_MS.to_vec());

    let text = serde_json::to_string(&dto).unwrap();
    assert_eq!(serde_json::from_str::<AdminMetricsDto>(&text).unwrap(), dto);
    assert_eq!(serde_json::from_str::<Value>(&text).unwrap(), raw);

    fn only_numbers(value: &Value, at: &str) {
        match value {
            Value::Number(_) => {}
            Value::Array(items) => items.iter().for_each(|item| only_numbers(item, at)),
            Value::Object(fields) => fields
                .iter()
                .for_each(|(name, item)| only_numbers(item, &format!("{at}.{name}"))),
            other => panic!("{at} is {other}, not a number"),
        }
    }
    only_numbers(&raw, "$");
    let _ = state;
}
