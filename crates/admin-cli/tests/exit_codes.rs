//! What the admin CLI's exit status says (#606 R9, docs/1.10 *What a script's
//! exit status means*): it reads the reason the server answers with, prints the
//! body's `detail`, and never says reqwest's words.
//!
//! The server is a stub that answers every request with one canned response, so
//! each row of the design's table is reached directly, `AdminLoopbackOnly` and a
//! 503 included, which a real server on loopback cannot be made to send.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener};
use std::process::{Command, Output};

use api::{ApiError, ErrorType, Reason};

/// Answers every connection with `status`, `content_type` and `body`, forever.
fn stub(status: u16, content_type: &'static str, body: String) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("a port");
    let address = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut seen = Vec::new();
            let mut byte = [0u8; 1];
            while !seen.ends_with(b"\r\n\r\n") {
                if stream.read(&mut byte).unwrap_or(0) == 0 {
                    break;
                }
                seen.push(byte[0]);
            }
            let response = format!(
                "HTTP/1.1 {status} Whatever\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(response.as_bytes());
        }
    });
    address
}

fn problem_body(reason: Reason, detail: &str) -> String {
    serde_json::to_string(&ApiError {
        message: detail.to_string(),
        status: reason.status(),
        detail: detail.to_string(),
        outcome: "fatal".to_string(),
        error_type: Some(reason.error_type()),
        blip: reason.blip(),
        reason: Some(reason),
        domain: "tile-lite-elite".to_string(),
        ..ApiError::default()
    })
    .unwrap()
}

fn admin(address: SocketAddr, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_tile-lite-elite-admin"))
        .arg("--server")
        .arg(format!("http://{address}"))
        .args(args)
        .output()
        .expect("the CLI should run")
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// Every reason the server sends, answered as the design's table says, and the
/// operator reads the detail and nothing of reqwest's.
#[test]
fn every_reason_exits_by_its_type() {
    for &reason in Reason::ALL {
        let detail = format!("The detail for {reason:?}.");
        let address = stub(
            reason.status(),
            "application/problem+json",
            problem_body(reason, &detail),
        );
        let output = admin(address, &["size"]);
        let expected = match (reason, reason.error_type(), reason.blip()) {
            (Reason::AdminLoopbackOnly, _, _) => 2,
            (_, ErrorType::Business, _) => 1,
            (_, ErrorType::Technical, true) => 75,
            (_, ErrorType::Technical, false) => 2,
            _ => 70,
        };
        assert_eq!(
            output.status.code(),
            Some(expected),
            "{reason:?}: {}",
            text(&output.stderr)
        );
        let stderr = text(&output.stderr);
        assert!(stderr.contains(&detail), "{reason:?}: {stderr}");
        assert!(
            !stderr.contains("reqwest") && !stderr.contains("error sending request"),
            "{stderr}"
        );
        assert!(output.stdout.is_empty(), "{reason:?}: nothing on stdout");
    }
}

#[test]
fn a_connection_that_is_refused_is_a_blip() {
    // A port nothing listens on: bind, note it, drop.
    let address = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    let output = admin(address, &["size"]);
    assert_eq!(output.status.code(), Some(75), "{}", text(&output.stderr));
    let stderr = text(&output.stderr);
    assert!(stderr.contains("Could not reach the server"), "{stderr}");
    assert!(!stderr.contains("reqwest") && !stderr.contains("error sending request"));
}

#[test]
fn a_body_the_tool_cannot_parse_is_unexpected_whatever_the_status() {
    for status in [200u16, 404, 502] {
        let address = stub(
            status,
            "text/html",
            "<html>a proxy's page</html>".to_string(),
        );
        let output = admin(address, &["size"]);
        assert_eq!(
            output.status.code(),
            Some(70),
            "{status}: {}",
            text(&output.stderr)
        );
        assert!(!text(&output.stderr).contains("proxy's page"));
    }
}

/// A server that predates reasons, or a reason this build does not know, is
/// read by its status.
#[test]
fn an_answer_without_a_known_reason_is_read_by_its_status() {
    for (status, body, expected) in [
        (404, r#"{"message":"Player not found"}"#, 1),
        (401, r#"{"message":"Sign in"}"#, 2),
        (429, r#"{"message":"Slow down"}"#, 75),
        (503, r#"{"message":"Busy"}"#, 75),
        (500, r#"{"message":"Broke"}"#, 70),
        (
            404,
            r#"{"detail":"Newer","reason":"A_REASON_FROM_THE_FUTURE"}"#,
            1,
        ),
    ] {
        let address = stub(status, "application/json", body.to_string());
        let output = admin(address, &["size"]);
        assert_eq!(output.status.code(), Some(expected), "{status} {body}");
    }
}

/// Under `--json` the error's body goes to stdout as a success's does, and
/// nothing goes to stderr.
#[test]
fn json_prints_the_error_body_to_stdout() {
    let body = problem_body(Reason::PlayerNotFound, "Player not found");
    let address = stub(404, "application/problem+json", body);
    let output = admin(address, &["--json", "size"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stderr.is_empty(), "{}", text(&output.stderr));
    let printed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON on stdout");
    assert_eq!(printed["reason"], "PLAYER_NOT_FOUND");
    assert_eq!(printed["detail"], "Player not found");

    // ...and for a failure that never reached an answer.
    let dead = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    let output = admin(dead, &["--json", "size"]);
    assert_eq!(output.status.code(), Some(75));
    assert!(output.stderr.is_empty());
    let printed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON on stdout");
    assert_eq!(printed["error_type"], "technical");
    assert_eq!(printed["blip"], true);
}

#[test]
fn a_usage_error_exits_64_and_help_lists_the_exit_codes() {
    let address = "127.0.0.1:9".parse().unwrap();
    let usage = admin(address, &["no-such-command"]);
    assert_eq!(usage.status.code(), Some(64), "{}", text(&usage.stderr));
    let missing = admin(address, &["users", "delete"]);
    assert_eq!(missing.status.code(), Some(64));

    let help = admin(address, &["--help"]);
    assert_eq!(help.status.code(), Some(0));
    let help = text(&help.stdout);
    for code in ["0 ", "1 ", "2 ", "64", "70", "75"] {
        assert!(
            help.lines()
                .any(|line| line.trim_start().starts_with(code) && help.contains("Exit codes")),
            "--help lists {code}: {help}"
        );
    }
}

/// A success is still 0, and still prints a table.
#[test]
fn a_success_exits_0() {
    let address = stub(200, "application/json", "[]".to_string());
    let output = admin(address, &["size"]);
    assert_eq!(output.status.code(), Some(0), "{}", text(&output.stderr));
}

/// An address that is not a URL is the operator's setting at fault (2), not a
/// server that is down (75), and says so without reqwest's words.
#[test]
fn a_malformed_server_address_is_a_fundamental_error() {
    for server in ["not a url", "ftp://127.0.0.1", ""] {
        let output = Command::new(env!("CARGO_BIN_EXE_tile-lite-elite-admin"))
            .arg("--server")
            .arg(server)
            .arg("size")
            .output()
            .expect("the CLI should run");
        assert_eq!(
            output.status.code(),
            Some(2),
            "{server:?}: {}",
            text(&output.stderr)
        );
        let stderr = text(&output.stderr);
        assert!(stderr.contains("--server"), "{stderr}");
        assert!(
            !stderr.contains("reqwest") && !stderr.contains("builder"),
            "{stderr}"
        );
    }
    // And with --json the body is the technical, fundamental one.
    let output = Command::new(env!("CARGO_BIN_EXE_tile-lite-elite-admin"))
        .args(["--server", "not a url", "--json", "size"])
        .output()
        .expect("the CLI should run");
    assert_eq!(output.status.code(), Some(2));
    let printed: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("JSON on stdout");
    assert_eq!(printed["error_type"], "technical");
    assert_eq!(printed["blip"], false);
    // A refused connection to a good address is still a blip (75).
    let dead = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    assert_eq!(admin(dead, &["size"]).status.code(), Some(75));
}

fn sample_metrics() -> api::AdminMetricsDto {
    api::AdminMetricsDto {
        started_at: 1_785_073_922,
        responses: api::AdminResponseCountsDto {
            informational: 3,
            success: 412,
            redirection: 0,
            client_error: 9,
            server_error: 0,
        },
        errors: api::AdminErrorTypeCountsDto {
            business: 6,
            technical: 3,
            unexpected: 0,
            unclassified: 0,
        },
        too_many_requests: 1,
        service_unavailable: 0,
        panics_caught: 0,
        websocket_handshake_failures: 2,
        latency: api::AdminLatencyDto {
            bounds_ms: vec![10, 50, 100, 250, 500, 1_000, 5_000, 60_000],
            counts: vec![380, 31, 8, 3, 1, 1, 0, 0, 0],
        },
    }
}

/// T14: `metrics` exits by the reason it is answered with, as every command
/// does (R9), and says the detail and nothing of reqwest's.
#[test]
fn metrics_exits_by_the_reason_it_is_answered_with() {
    for (reason, expected) in [
        (Reason::AdminLoopbackOnly, 2),
        (Reason::ServiceBusy, 75),
        (Reason::Internal, 70),
        (Reason::NoSuchRoute, 1),
    ] {
        let detail = format!("The detail for {reason:?}.");
        let address = stub(
            reason.status(),
            "application/problem+json",
            problem_body(reason, &detail),
        );
        let output = admin(address, &["metrics"]);
        assert_eq!(
            output.status.code(),
            Some(expected),
            "{reason:?}: {}",
            text(&output.stderr)
        );
        assert!(text(&output.stderr).contains(&detail));
        assert!(output.stdout.is_empty(), "{reason:?}: nothing on stdout");
    }
    let dead = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap();
    assert_eq!(admin(dead, &["metrics"]).status.code(), Some(75));
}

/// T14: the table names each counter and bucket with the start time in UTC,
/// and `--json` prints the DTO unchanged.
#[test]
fn metrics_prints_a_table_and_under_json_the_dto() {
    let dto = sample_metrics();
    let body = serde_json::to_string(&dto).unwrap();
    let address = stub(200, "application/json", body);

    let table = admin(address, &["metrics"]);
    assert_eq!(table.status.code(), Some(0), "{}", text(&table.stderr));
    let table = text(&table.stdout);
    assert!(table.contains("2026-07-26 13:52:02 UTC"), "{table}");
    // Whole rows, name and count, so two swapped labels fail.
    for (name, count) in [
        ("responses: informational (1xx)", "3"),
        ("responses: success (2xx)", "412"),
        ("responses: redirection (3xx)", "0"),
        ("responses: client error (4xx)", "9"),
        ("responses: server error (5xx)", "0"),
        ("errors: business", "6"),
        ("errors: technical", "3"),
        ("errors: unexpected", "0"),
        ("errors: unclassified", "0"),
        ("too many requests (429)", "1"),
        ("service unavailable (503)", "0"),
        ("panics caught", "0"),
        ("websocket handshake failures", "2"),
        ("<= 10 ms", "380"),
        ("<= 50 ms", "31"),
        ("<= 100 ms", "8"),
        ("<= 250 ms", "3"),
        ("<= 500 ms", "1"),
        ("<= 1000 ms", "1"),
        ("<= 5000 ms", "0"),
        ("<= 60000 ms", "0"),
        ("> 60000 ms", "0"),
    ] {
        let line = table
            .lines()
            .find(|line| line.trim_start().starts_with(name))
            .unwrap_or_else(|| panic!("{name} in {table}"));
        let cells: Vec<&str> = line.split("  ").filter(|c| !c.trim().is_empty()).collect();
        assert_eq!((cells[0].trim(), cells[1].trim()), (name, count), "{line}");
    }

    let json = admin(address, &["--json", "metrics"]);
    assert_eq!(json.status.code(), Some(0));
    let printed: api::AdminMetricsDto =
        serde_json::from_slice(&json.stdout).expect("the DTO on stdout");
    assert_eq!(printed, dto);
}
