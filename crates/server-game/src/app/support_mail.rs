//! The service desk's intake trigger (#518, project #515). Mail to the support
//! address lands in Resend; this job notices that something new has arrived and
//! starts the `intake` workflow in `delphside/service-desk`, which does the
//! reading. The server only knows *that* mail arrived, never what it says: it
//! reads one id from Resend and hands nothing on, so no sender, subject or body
//! passes through this process.
//!
//! The newest message's id is remembered in memory only. **The first pass
//! after a start only remembers it, and dispatches nothing**: a server in a
//! crash-restart loop must not start a workflow run per restart. Mail that
//! arrived while the server was down is collected by the desk's own 30-minute
//! schedule. If the mailbox is empty on that first pass, nothing is
//! remembered, and the first message to arrive afterwards dispatches.

use std::time::Duration;

use tokio::sync::Mutex;

use super::AppState;

const RESEND_BASE_URL: &str = "https://api.resend.com";
const GITHUB_BASE_URL: &str = "https://api.github.com";
const INTAKE_DISPATCH_PATH: &str =
    "/repos/delphside/service-desk/actions/workflows/intake.yml/dispatches";
const USER_AGENT: &str = "tile-lite-elite-support-poller";

/// Bounds each call, so a hung Resend or GitHub costs one pass and not the
/// tier. Ten seconds is generous for a one-item list and an empty-bodied POST.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// Both secrets, and where to send them. The base URLs are fields so a test can
/// point the poller at a local stub; `new` gives the real ones.
#[derive(Clone)]
pub struct SupportMailConfig {
    resend_api_key: String,
    github_token: String,
    pub(crate) resend_base_url: String,
    pub(crate) github_base_url: String,
}

impl SupportMailConfig {
    /// `None` unless both settings are present and non-empty, which is how
    /// "either unset means the job is not registered" is decided.
    pub fn new(resend_api_key: Option<String>, github_token: Option<String>) -> Option<Self> {
        let resend_api_key = resend_api_key.filter(|key| !key.is_empty())?;
        let github_token = github_token.filter(|token| !token.is_empty())?;
        Some(Self {
            resend_api_key,
            github_token,
            resend_base_url: RESEND_BASE_URL.to_string(),
            github_base_url: GITHUB_BASE_URL.to_string(),
        })
    }
}

/// What the poller remembers between passes.
struct Memory {
    /// True until a pass has read the mailbox successfully.
    first_pass: bool,
    /// The newest message already dispatched for, or seen on the first pass.
    last_seen: Option<String>,
}

/// The poller's state: configuration, one client built once, and its memory.
pub(crate) struct SupportMail {
    config: SupportMailConfig,
    client: reqwest::Client,
    memory: Mutex<Memory>,
}

impl SupportMail {
    pub(crate) fn new(config: SupportMailConfig) -> Self {
        let client = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .expect("an HTTP client with only a timeout set should build");
        Self {
            config,
            client,
            memory: Mutex::new(Memory {
                first_pass: true,
                last_seen: None,
            }),
        }
    }

    /// One pass. Returns the number of errors (0 or 1) for the scheduler's
    /// health numbers. The first successful read only remembers the newest id;
    /// after that an id is remembered once its dispatch has succeeded, so any
    /// failure leaves the memory unchanged and is retried on the next pass.
    async fn poll(&self) -> u64 {
        let latest = self.latest_message_id().await;
        let mut memory = self.memory.lock().await;
        let latest = match latest {
            Ok(Some(id)) => id,
            Ok(None) => {
                memory.first_pass = false;
                return 0;
            }
            Err(()) => return 1,
        };
        if std::mem::take(&mut memory.first_pass) {
            memory.last_seen = Some(latest);
            return 0;
        }
        if memory.last_seen.as_deref() == Some(latest.as_str()) {
            return 0;
        }
        if !self.handle_new_message(&latest).await {
            return 1;
        }
        memory.last_seen = Some(latest);
        0
    }

    /// The step taken for each message not yet seen. Today it dispatches the
    /// intake workflow.
    async fn handle_new_message(&self, _id: &str) -> bool {
        self.dispatch_intake().await
    }

    /// The newest received message's id, the one field read from the response.
    /// `Ok(None)` is an empty mailbox; `Err` has been logged.
    async fn latest_message_id(&self) -> Result<Option<String>, ()> {
        let url = format!("{}/emails/receiving?limit=1", self.config.resend_base_url);
        let response = self
            .client
            .get(url)
            .bearer_auth(&self.config.resend_api_key)
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .send()
            .await
            .map_err(|error| {
                tracing::warn!(%error, "support mail check failed");
            })?;
        let status = response.status();
        if !status.is_success() {
            tracing::warn!(%status, "support mail check failed");
            return Err(());
        }
        // The body is parsed and dropped, never logged: it describes mail.
        let body: serde_json::Value = response.json().await.map_err(|error| {
            tracing::warn!(%error, "support mail check failed");
        })?;
        match body["data"].as_array() {
            Some(data) if data.is_empty() => Ok(None),
            Some(data) => match data[0]["id"].as_str() {
                Some(id) => Ok(Some(id.to_string())),
                None => {
                    tracing::warn!(
                        error = "no message id in response",
                        "support mail check failed"
                    );
                    Err(())
                }
            },
            None => {
                tracing::warn!(
                    error = "no message list in response",
                    "support mail check failed"
                );
                Err(())
            }
        }
    }

    /// Starts the service desk's intake workflow. GitHub answers 204.
    async fn dispatch_intake(&self) -> bool {
        let url = format!("{}{INTAKE_DISPATCH_PATH}", self.config.github_base_url);
        let response = self
            .client
            .post(url)
            .bearer_auth(&self.config.github_token)
            .header(reqwest::header::ACCEPT, "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .json(&serde_json::json!({ "ref": "main" }))
            .send()
            .await;
        match response {
            Ok(response) if response.status().is_success() => {
                tracing::info!("support intake dispatched");
                true
            }
            Ok(response) => {
                let status = response.status();
                tracing::warn!(%status, "support intake dispatch failed");
                false
            }
            Err(error) => {
                tracing::warn!(%error, "support intake dispatch failed");
                false
            }
        }
    }
}

/// The scheduled job: one pass of the poller. `0` when it is not configured,
/// though it is not registered then.
pub(super) async fn poll_support_mail(state: &AppState) -> u64 {
    match &state.support_mail {
        Some(support_mail) => support_mail.poll().await,
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;

    /// One recorded request: request line, lower-cased head, body.
    struct Seen {
        request_line: String,
        headers: String,
        body: String,
    }

    #[derive(Default)]
    struct StubState {
        /// Replies to `GET .../emails/receiving`, in order; the last repeats.
        resend: VecDeque<(u16, String)>,
        /// Reply to the dispatch POST.
        dispatch_status: u16,
        seen: Vec<Seen>,
    }

    /// A local stand-in for both Resend and GitHub, on a thread: the crate's
    /// tokio features have no I/O traits, and a blocking listener needs none.
    struct Stub {
        base_url: String,
        state: Arc<std::sync::Mutex<StubState>>,
    }

    impl Stub {
        fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").expect("a loopback port should bind");
            let base_url = format!("http://{}", listener.local_addr().unwrap());
            let state = Arc::new(std::sync::Mutex::new(StubState {
                dispatch_status: 204,
                ..Default::default()
            }));
            let shared = state.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { continue };
                    let mut buffer = Vec::new();
                    let mut chunk = [0u8; 4096];
                    let (head_end, length) = loop {
                        let n = stream.read(&mut chunk).unwrap_or(0);
                        if n == 0 {
                            break (buffer.len(), 0);
                        }
                        buffer.extend_from_slice(&chunk[..n]);
                        if let Some(at) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&buffer[..at]).to_lowercase();
                            let length = head
                                .lines()
                                .find_map(|line| line.strip_prefix("content-length: "))
                                .and_then(|value| value.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                            break (at + 4, length);
                        }
                    };
                    while buffer.len() < head_end + length {
                        let n = stream.read(&mut chunk).unwrap_or(0);
                        if n == 0 {
                            break;
                        }
                        buffer.extend_from_slice(&chunk[..n]);
                    }
                    let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
                    let body = String::from_utf8_lossy(&buffer[head_end..]).to_string();
                    let request_line = head.lines().next().unwrap_or("").to_string();
                    let (status, reply) = {
                        let mut state = shared.lock().unwrap();
                        let reply = if request_line.starts_with("GET /emails/receiving") {
                            if state.resend.len() > 1 {
                                state.resend.pop_front().unwrap()
                            } else {
                                state
                                    .resend
                                    .front()
                                    .cloned()
                                    .unwrap_or((500, String::new()))
                            }
                        } else {
                            (state.dispatch_status, String::new())
                        };
                        state.seen.push(Seen {
                            request_line,
                            headers: head.to_lowercase(),
                            body,
                        });
                        reply
                    };
                    let _ = write!(
                        stream,
                        "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{reply}",
                        reply.len()
                    );
                }
            });
            Self { base_url, state }
        }

        fn resend_replies(&self, replies: &[(u16, &str)]) {
            self.state.lock().unwrap().resend = replies
                .iter()
                .map(|(status, body)| (*status, body.to_string()))
                .collect();
        }

        fn dispatch_replies_with(&self, status: u16) {
            self.state.lock().unwrap().dispatch_status = status;
        }

        fn dispatches(&self) -> usize {
            self.state
                .lock()
                .unwrap()
                .seen
                .iter()
                .filter(|seen| seen.request_line.starts_with("POST "))
                .count()
        }
    }

    fn list_with(id: &str) -> String {
        format!(
            r#"{{"object":"list","data":[{{"id":"{id}","subject":"ignored"}}],"has_more":false}}"#
        )
    }

    const EMPTY_LIST: &str = r#"{"object":"list","data":[],"has_more":false}"#;

    async fn poller_against(stub: &Stub) -> AppState {
        let url = crate::app::tests::test_database_url();
        let state = crate::app::tests::create_test_state(&url).await;
        let mut config = SupportMailConfig::new(
            Some("resend-key".to_string()),
            Some("github-token".to_string()),
        )
        .expect("both settings are present");
        config.resend_base_url = stub.base_url.clone();
        config.github_base_url = stub.base_url.clone();
        state.with_support_mail(Some(config))
    }

    #[test]
    fn the_poller_needs_both_settings_non_empty() {
        let set = || Some("x".to_string());
        assert!(SupportMailConfig::new(set(), set()).is_some());
        assert!(SupportMailConfig::new(None, set()).is_none());
        assert!(SupportMailConfig::new(set(), None).is_none());
        assert!(SupportMailConfig::new(Some(String::new()), set()).is_none());
        assert!(SupportMailConfig::new(set(), Some(String::new())).is_none());
    }

    #[tokio::test]
    async fn a_new_message_dispatches_once_with_the_headers_github_needs() {
        let stub = Stub::start();
        stub.resend_replies(&[(200, &list_with("m0")), (200, &list_with("m1"))]);
        let state = poller_against(&stub).await;

        assert_eq!(poll_support_mail(&state).await, 0);
        assert_eq!(stub.dispatches(), 0, "the first pass only remembers");
        assert_eq!(poll_support_mail(&state).await, 0);

        assert_eq!(stub.dispatches(), 1);
        let guard = stub.state.lock().unwrap();
        let get = &guard.seen[0];
        assert!(
            get.request_line
                .starts_with("GET /emails/receiving?limit=1 ")
        );
        assert!(get.headers.contains("authorization: bearer resend-key"));
        assert!(get.headers.contains("user-agent: "));
        let post = guard
            .seen
            .iter()
            .find(|seen| seen.request_line.starts_with("POST "))
            .expect("a dispatch was made");
        assert!(post.request_line.starts_with(
            "POST /repos/delphside/service-desk/actions/workflows/intake.yml/dispatches "
        ));
        assert!(post.headers.contains("authorization: bearer github-token"));
        assert!(post.headers.contains("accept: application/vnd.github+json"));
        assert!(post.headers.contains("x-github-api-version: 2022-11-28"));
        assert!(post.headers.contains("user-agent: "));
        assert_eq!(post.body, r#"{"ref":"main"}"#);
    }

    #[tokio::test]
    async fn the_same_message_on_the_next_pass_does_not_dispatch_again() {
        let stub = Stub::start();
        stub.resend_replies(&[(200, &list_with("m0")), (200, &list_with("m1"))]);
        let state = poller_against(&stub).await;

        for _ in 0..4 {
            assert_eq!(poll_support_mail(&state).await, 0);
        }

        assert_eq!(stub.dispatches(), 1);
    }

    #[tokio::test]
    async fn a_newer_message_dispatches_again() {
        let stub = Stub::start();
        stub.resend_replies(&[
            (200, &list_with("m0")),
            (200, &list_with("m1")),
            (200, &list_with("m2")),
        ]);
        let state = poller_against(&stub).await;

        for _ in 0..3 {
            poll_support_mail(&state).await;
        }

        assert_eq!(stub.dispatches(), 2);
    }

    #[tokio::test]
    async fn a_restart_remembers_what_is_there_and_dispatches_only_for_what_follows() {
        // A crash-restart loop must not start a workflow run per restart: the
        // fresh process finds m1 already dispatched for by its predecessor and
        // does not dispatch for it again.
        let stub = Stub::start();
        stub.resend_replies(&[
            (200, &list_with("m0")),
            (200, &list_with("m1")),
            (200, &list_with("m1")),
            (200, &list_with("m2")),
        ]);
        let before = poller_against(&stub).await;
        poll_support_mail(&before).await;
        poll_support_mail(&before).await;
        assert_eq!(stub.dispatches(), 1, "state A dispatches for m1");

        let after = poller_against(&stub).await;
        assert_eq!(poll_support_mail(&after).await, 0);
        assert_eq!(stub.dispatches(), 1, "state B's first pass does not");

        poll_support_mail(&after).await;
        assert_eq!(stub.dispatches(), 2, "m2 arriving after the restart does");
    }

    #[tokio::test]
    async fn an_empty_mailbox_dispatches_nothing_and_the_first_message_after_it_does() {
        let stub = Stub::start();
        stub.resend_replies(&[
            (200, EMPTY_LIST),
            (200, EMPTY_LIST),
            (200, &list_with("m1")),
        ]);
        let state = poller_against(&stub).await;

        assert_eq!(poll_support_mail(&state).await, 0);
        assert_eq!(poll_support_mail(&state).await, 0);
        assert_eq!(stub.dispatches(), 0);

        poll_support_mail(&state).await;
        assert_eq!(
            stub.dispatches(),
            1,
            "an empty first pass remembers nothing, so m1 is new"
        );
    }

    #[tokio::test]
    async fn a_failed_resend_call_is_an_error_and_leaves_the_remembered_id_alone() {
        let stub = Stub::start();
        stub.resend_replies(&[
            (200, &list_with("m1")),
            (500, ""),
            (200, &list_with("m1")),
            (500, ""),
            (200, &list_with("m2")),
        ]);
        let state = poller_against(&stub).await;

        assert_eq!(poll_support_mail(&state).await, 0, "m1 is remembered");
        assert_eq!(
            poll_support_mail(&state).await,
            1,
            "one error for the failed call"
        );
        assert_eq!(poll_support_mail(&state).await, 0);
        assert_eq!(
            stub.dispatches(),
            0,
            "the failure forgot nothing: m1 is still not new"
        );

        // A failure must not count as a restart either: m2 straight after
        // a failed call is new, and dispatches at once.
        assert_eq!(poll_support_mail(&state).await, 1);
        poll_support_mail(&state).await;
        assert_eq!(stub.dispatches(), 1, "and the next real message dispatches");
    }

    #[tokio::test]
    async fn a_failed_dispatch_is_an_error_and_does_not_remember_the_message() {
        let stub = Stub::start();
        stub.resend_replies(&[(200, &list_with("m0")), (200, &list_with("m1"))]);
        stub.dispatch_replies_with(403);
        let state = poller_against(&stub).await;

        poll_support_mail(&state).await;
        assert_eq!(
            poll_support_mail(&state).await,
            1,
            "one error for the failed dispatch"
        );
        assert_eq!(stub.dispatches(), 1);

        stub.dispatch_replies_with(204);
        assert_eq!(poll_support_mail(&state).await, 0);
        assert_eq!(
            stub.dispatches(),
            2,
            "the message that failed to dispatch is tried again, not skipped"
        );
    }
}
