//! Deleting an account through the real CLI binary, over a real connection.
//!
//! Rules: `docs/1.0-rules.md`, DEL-1, DEL-2, DEL-8 and DEL-9. Test plan:
//! issue #41.
//!
//! Everything else in this plan hands a `Request` straight to the server with
//! `tower`'s `oneshot` — routing, middleware, extractors and handlers all run,
//! but no networking below HTTP is involved and no separate process exists.
//! This one crosses both boundaries: the test hosts the server on a loopback
//! port, and the CLI is a separate executable dialling it over TCP.
//!
//! That covers two things the in-process tests cannot reach.
//!
//! The CLI is the only route to deleting an account for anyone in production
//! (DEL-1), so its own behaviour — resolving a name to an account, the exit
//! code, the message — is otherwise untested.
//!
//! And admin routes are guarded by `require_loopback`, which reads the
//! caller's address from `ConnectInfo` to check the connection is local to the
//! machine. `ConnectInfo` is an extractor Axum fills in only when the server is
//! started with `into_make_service_with_connect_info::<SocketAddr>()`, as
//! `main.rs` does. `oneshot` never starts a server, so nothing fills it in and
//! those tests insert an address themselves, which exercises the guard against
//! a value they chose. Here the kernel reports it, so this also proves the
//! wiring is still there — remove that line from `main.rs` and every
//! in-process test still passes while admin breaks in production.
//!
//! `cargo test` builds the binary and hands its path over as
//! `CARGO_BIN_EXE_tile-lite-elite-admin`, which is set only for tests in the
//! package that defines it. Nothing is installed and nothing is running first.

use std::net::SocketAddr;
use std::process::{Command, Output};

use server_game::{AppState, build_router};

struct Server {
    address: SocketAddr,
    client: reqwest::blocking::Client,
}

impl Server {
    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.address)
    }

    /// Signs a session out, so the account stops being "in use".
    ///
    /// Deleting an account that somebody is signed in as is refused (#82), and
    /// registering signs you in — so every account this test creates is in use
    /// until it does this. That refusal is covered in
    /// `tests_account_lifecycle`; here it is setup, and skipping it would have
    /// this test fail for a reason it is not about.
    fn log_out(&self, token: &str) {
        let response = self
            .client
            .post(self.url("/auth/logout"))
            .bearer_auth(token)
            .send()
            .expect("logging out should reach the server");
        assert!(
            response.status().is_success(),
            "logging out should succeed, got {}",
            response.status()
        );
    }

    /// Registers a player and returns their account id and session token.
    fn register(&self, display_name: &str) -> (String, String) {
        let response = self
            .client
            .post(self.url("/auth/register"))
            .json(&serde_json::json!({
                "display_name": display_name,
                "email": format!("{}@example.com", display_name.to_lowercase()),
                "password": "correct horse battery staple",
                "stay_logged_in": false,
            }))
            .send()
            .expect("registering should reach the server");
        assert!(response.status().is_success(), "registering should succeed");
        let body: serde_json::Value = response.json().expect("a session should come back");
        (
            body["player_id"].as_str().expect("player_id").to_string(),
            body["session_token"]
                .as_str()
                .expect("session_token")
                .to_string(),
        )
    }

    /// An unstarted game created by `token`'s owner, with one open seat.
    fn create_waiting_game(&self, token: &str) -> String {
        let response = self
            .client
            .post(self.url("/games"))
            .bearer_auth(token)
            .json(&serde_json::json!({
                "seats": [
                    { "kind": "human", "display_name": "Creator", "claim": { "type": "creator" } },
                    { "kind": "human", "display_name": "Second seat", "claim": { "type": "open" } },
                ],
                "seed": 42,
            }))
            .send()
            .expect("creating a game should reach the server");
        assert!(
            response.status().is_success(),
            "creating a game should succeed, got {}",
            response.status()
        );
        let body: serde_json::Value = response.json().expect("a game should come back");
        body["id"].as_str().expect("game id").to_string()
    }

    fn admin(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_tile-lite-elite-admin"))
            .arg("--server")
            .arg(format!("http://{}", self.address))
            .args(args)
            .output()
            .expect("the admin binary should run")
    }
}

/// Starts a server on a loopback port of the kernel's choosing, served the way
/// `main.rs` serves it. Leaks the runtime deliberately: it lives as long as
/// the test process, and there is nothing to tidy in a test binary that is
/// about to exit.
fn start_server() -> Server {
    let runtime = Box::leak(Box::new(
        tokio::runtime::Runtime::new().expect("a runtime should start"),
    ));

    let address = runtime.block_on(async {
        let path = std::env::temp_dir().join(format!(
            "tile-lite-elite-admin-cli-test-{}.sqlite3",
            uuid::Uuid::new_v4()
        ));
        std::fs::File::create(&path).expect("a database file should be creatable");
        let state = AppState::new(
            &format!("sqlite://{}", path.display()),
            "http://127.0.0.1:0".to_string(),
            server_game::email::EmailConfig::new(
                None,
                "Tile Lite Elite <noreply@example.com>".to_string(),
            ),
        )
        .await
        .expect("the server should initialise");

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("binding a loopback port should work");
        let address = listener.local_addr().expect("the port should be readable");

        tokio::spawn(async move {
            axum::serve(
                listener,
                build_router(state).into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .expect("the server should serve");
        });
        address
    });

    Server {
        address,
        client: reqwest::blocking::Client::new(),
    }
}

#[test]
fn deleting_a_user_through_the_cli() {
    let server = start_server();
    let (alice_id, alice_token) = server.register("AliceCli");
    let game_id = server.create_waiting_game(&alice_token);

    // By display name, while she still has a game. DEL-2 refuses, and DEL-9
    // says the name reaches the same account an id would.
    let refused = server.admin(&["users", "delete", "AliceCli"]);
    assert!(
        !refused.status.success(),
        "a refused delete should exit non-zero, so a script notices"
    );
    let complaint =
        String::from_utf8_lossy(&refused.stderr) + String::from_utf8_lossy(&refused.stdout);
    assert!(
        complaint.contains(&game_id),
        "the refusal should name the game in the way, said: {complaint}"
    );

    // Clear the game the way an administrator would, with the other command.
    let game_deleted = server.admin(&["games", "delete", &game_id]);
    assert!(
        game_deleted.status.success(),
        "deleting the game should succeed: {}",
        String::from_utf8_lossy(&game_deleted.stderr)
    );

    // Signed out first: an account in use is refused for a different reason,
    // and this test is about the game attachments.
    server.log_out(&alice_token);

    // Now by account id, which must reach the same account the name did.
    let deleted = server.admin(&["users", "delete", &alice_id]);
    assert!(
        deleted.status.success(),
        "with nothing referring to her, the delete should succeed: {}",
        String::from_utf8_lossy(&deleted.stderr)
    );

    // And she is really gone, rather than merely reported as deleted.
    let again = server.admin(&["users", "delete", &alice_id]);
    assert!(
        !again.status.success(),
        "deleting her twice should fail the second time"
    );
}
