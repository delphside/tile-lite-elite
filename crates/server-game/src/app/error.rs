use super::*;

use api::{ErrorType, Reason, Violation};

/// **The one 500 sentence**, stated in 4.4.3's `Internal` row and read from
/// here by every 500. It says what happened and where the cause is, and it
/// does not say *try again*: that told a caller to loop on a defect. The
/// words of whatever failed go to the log, never into the body.
pub(crate) const INTERNAL_MESSAGE: &str = "Something went wrong on the server. It has been logged.";

/// What a database or hashing failure that is load rather than fault says.
pub(crate) const BUSY_MESSAGE: &str = "The service is busy just now. Please try again in a moment.";

/// The `domain` of every reason this application names (docs/1.10 *The result
/// object*).
pub(crate) const ERROR_DOMAIN: &str = "tile-lite-elite";

/// What a body that cannot be serialised answers: fixed, so the one failure
/// inside the error path still answers `application/problem+json` and still
/// says nothing it should not. Kept in step with `INTERNAL_MESSAGE` by a test.
const FALLBACK_BODY: &str = r#"{"title":"Internal Server Error","status":500,"detail":"Something went wrong on the server. It has been logged.","message":"Something went wrong on the server. It has been logged.","outcome":"fatal","error_type":"unexpected","blip":false,"reason":"INTERNAL","domain":"tile-lite-elite"}"#;

pub(crate) const PROBLEM_JSON: &str = "application/problem+json";

tokio::task_local! {
    /// This request's ID, set by `request_id_layer` before routing. A
    /// task-local because the log writes no span fields (`main.rs` sets
    /// `with_current_span(false)`), so a line has no other way to say which
    /// request it belongs to.
    static REQUEST_ID: String;
}

/// The ID of the request this task is serving, or `None` outside one (a
/// scheduled job, a WebSocket's own task).
pub(crate) fn current_request_id() -> Option<String> {
    REQUEST_ID.try_with(Clone::clone).ok()
}

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// 12 Crockford base32 characters from 60 random bits: short enough to read
/// out, and a collision is likely only after about a billion requests.
pub(crate) fn new_request_id() -> String {
    use rand::Rng;
    let bits: u64 = rand::thread_rng().r#gen::<u64>() >> 4;
    (0..12)
        .rev()
        .map(|group| CROCKFORD[((bits >> (group * 5)) & 0x1f) as usize] as char)
        .collect()
}

/// **The middleware that gives every request an ID.** It drops any
/// `x-request-id` the caller sent (a caller's own ID could forge log lines,
/// and nothing in front of the server sets one), makes a fresh one, sets it on
/// the request and on the response, success included, and holds it for the
/// task so the error lines can read it.
pub(crate) async fn request_id_layer(mut request: Request, next: Next) -> Response {
    let id = new_request_id();
    let value = axum::http::HeaderValue::from_str(&id).expect("an ID is ASCII");
    request.headers_mut().insert("x-request-id", value.clone());
    let mut response = REQUEST_ID.scope(id, next.run(request)).await;
    response.headers_mut().insert("x-request-id", value);
    response
}

/// `Debug` so tests can `.expect()` on a `Result<_, ApiProblem>`; the
/// derive is harmless because the message is what the client receives, never
/// anything DB-sourced — see `ApiError`'s note in `crates/api`.
#[derive(Debug)]
pub struct ApiProblem {
    reason: Reason,
    message: String,
    /// Games standing in the way, sent alongside the message so a client can
    /// render them however suits it. Empty for everything except the refusals
    /// that have some to name.
    blocking_games: Vec<api::AdminGameSummaryDto>,
    /// The values outside a limit the API states.
    violations: Vec<Violation>,
    /// Seconds for a `Retry-After` header, set only on a 429 or a 503. A
    /// client that is told to come back should be told when — without it, a
    /// well-behaved client has to guess, and guessing usually means retrying
    /// immediately, which is the worst thing to do to a server that just said
    /// it was full.
    retry_after: Option<u32>,
}

impl ApiProblem {
    /// **A refusal names its reason, and the reason decides the status**, the
    /// type and the log level: a rule's refusal has no way to answer 401.
    pub(crate) fn new(reason: Reason, message: impl Into<String>) -> Self {
        Self {
            reason,
            message: message.into(),
            blocking_games: Vec::new(),
            violations: Vec::new(),
            retry_after: None,
        }
    }

    /// A refusal that can name the games responsible. The message still
    /// stands on its own, for a client that does not read the list.
    pub(crate) fn with_blocking_games(mut self, games: Vec<api::AdminGameSummaryDto>) -> Self {
        self.blocking_games = games;
        self
    }

    /// Says which value crossed which limit, as RFC 9457's `violations`.
    pub(crate) fn with_violation(mut self, field: &str, value: u64, limit: u64) -> Self {
        self.violations.push(Violation {
            field: field.to_string(),
            value,
            limit,
            reason: self.reason,
        });
        self
    }

    /// "Wait, then try again" is the useful part of a 429 or a 503.
    pub(crate) fn with_retry_after(mut self, seconds: u32) -> Self {
        self.retry_after = Some(seconds);
        self
    }

    /// The 500 every failure of the server's own answers, with the one
    /// sentence. The cause is logged by the caller.
    pub(crate) fn internal() -> Self {
        Self::new(Reason::Internal, INTERNAL_MESSAGE)
    }

    /// A database failure, classified — never the driver's own words. #380.
    ///
    /// `sqlx::Error::to_string()` renders schema. Measured 2026-09-13 against a
    /// real pool: table names, column names, constraint kinds, and for a
    /// malformed query a fragment of the SQL —
    /// `UNIQUE constraint failed: players.display_name_folded`. That went
    /// straight into the response body from a hundred call sites, and was
    /// reachable unauthenticated by two simultaneous registrations.
    ///
    /// **So the body says nothing and the detail goes to the log**, with the
    /// request's ID, which the body carries as `correlation_id` so a report can
    /// be matched to the line.
    ///
    /// **Transient or not is the other half, and it decides the reason.** A
    /// pool timeout, a closed pool and a locked database are load rather than
    /// faults — measured on #380 as `PoolTimedOut`, `PoolClosed` and SQLite
    /// code 5 — so they answer `ServiceBusy` (503) with `Retry-After`, because
    /// a client told to come back should be told when. Everything else is a bug
    /// or corruption and answers `Internal` (500).
    pub(crate) fn from_sqlx(error: sqlx::Error) -> Self {
        if Self::is_transient(&error) {
            tracing::warn!(%error, request_id = current_request_id(), "database unavailable — answering 503");
            return Self::new(Reason::ServiceBusy, BUSY_MESSAGE).with_retry_after(2);
        }
        tracing::error!(%error, request_id = current_request_id(), "database error");
        Self::internal()
    }

    /// Load rather than fault: worth retrying, and the caller did nothing wrong.
    ///
    /// SQLite's `5` is `SQLITE_BUSY` and `6` is `SQLITE_LOCKED`; the extended
    /// codes append to them, which is why this matches on the leading digit
    /// rather than on equality — `517` is `SQLITE_BUSY_SNAPSHOT` and is the
    /// same answer.
    fn is_transient(error: &sqlx::Error) -> bool {
        match error {
            sqlx::Error::PoolTimedOut | sqlx::Error::PoolClosed => true,
            sqlx::Error::Database(db) => matches!(
                db.code().as_deref(),
                Some(code) if code.starts_with('5') || code.starts_with('6')
            ),
            _ => false,
        }
    }

    /// A write that races a check-then-insert. #380 R5.
    ///
    /// `register_player` asks whether the name is taken, hashes the password —
    /// deliberately expensive, and queueing on a semaphore under load — and
    /// then inserts. Two concurrent registrations of the same name both pass
    /// the check, both hash, one inserts, and the other hits the unique index.
    ///
    /// **The check is an optimisation and the constraint is the truth**, so
    /// both answer the same sentence. Without this the loser got a 500 carrying
    /// `UNIQUE constraint failed: players.display_name_folded`.
    pub(crate) fn from_sqlx_or_duplicate(
        error: sqlx::Error,
        reason: Reason,
        message: &str,
    ) -> Self {
        if let sqlx::Error::Database(db) = &error
            && db.is_unique_violation()
        {
            return Self::new(reason, message);
        }
        Self::from_sqlx(error)
    }

    /// The reason this problem answers. Test-only: handlers decide by
    /// returning a reason, never by branching on one they were given.
    #[cfg(test)]
    pub(crate) fn reason_for_test(&self) -> Reason {
        self.reason
    }

    /// The status this problem will respond with. Test-only: a test asserting
    /// 503 rather than 429 is asserting the distinction the codes exist to make.
    #[cfg(test)]
    pub(crate) fn status_for_test(&self) -> StatusCode {
        self.status()
    }

    /// Test-only, for the same reason as `status_for_test`: the one thing worth
    /// asserting about a database failure is what the caller is told, and #380
    /// exists because that was the driver's own sentence.
    #[cfg(test)]
    pub(crate) fn message_for_test(&self) -> &str {
        &self.message
    }

    fn status(&self) -> StatusCode {
        StatusCode::from_u16(self.reason.status()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR)
    }

    fn body(&self) -> ApiError {
        let status = self.status();
        ApiError {
            message: self.message.clone(),
            title: status.canonical_reason().unwrap_or_default().to_string(),
            status: status.as_u16(),
            detail: self.message.clone(),
            outcome: "fatal".to_string(),
            error_type: Some(self.reason.error_type()),
            blip: self.reason.blip(),
            reason: Some(self.reason),
            domain: ERROR_DOMAIN.to_string(),
            violations: self.violations.clone(),
            blocking_games: self.blocking_games.clone(),
            correlation_id: current_request_id(),
        }
    }

    /// Split from `into_response` so a test can make serialising fail, the one
    /// failure inside the error path.
    fn render(
        self,
        serialize: impl FnOnce(&ApiError) -> Result<Vec<u8>, serde_json::Error>,
    ) -> Response {
        let reason = self.reason;
        let request_id = current_request_id();
        let code = reason_code(reason);
        // `info` for the caller's request, `warn` for the service or the
        // credential, `error` for a defect: docs/1.10 *The severity of an error*.
        match reason.error_type() {
            ErrorType::Business => tracing::info!(
                status = reason.status(),
                "error.type" = "business",
                error.reason = %code,
                error.domain = ERROR_DOMAIN,
                request_id,
                "request refused"
            ),
            ErrorType::Technical => tracing::warn!(
                status = reason.status(),
                "error.type" = "technical",
                error.reason = %code,
                error.domain = ERROR_DOMAIN,
                request_id,
                "request refused"
            ),
            _ => tracing::error!(
                status = reason.status(),
                "error.type" = "unexpected",
                error.reason = %code,
                error.domain = ERROR_DOMAIN,
                request_id,
                "request refused"
            ),
        }
        let (status, bytes) = match serialize(&self.body()) {
            Ok(bytes) => (self.status(), bytes),
            Err(error) => {
                tracing::error!(%error, request_id = current_request_id(), "an error body did not serialise; answering the fixed one");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    FALLBACK_BODY.as_bytes().to_vec(),
                )
            }
        };
        let mut response = (status, bytes).into_response();
        response.headers_mut().insert(
            axum::http::header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static(PROBLEM_JSON),
        );
        if let Some(secs) = self.retry_after
            && let Ok(value) = secs.to_string().parse()
        {
            response.headers_mut().insert("retry-after", value);
        }
        response
    }
}

/// The reason as the body and the log both write it: UPPER_SNAKE_CASE.
fn reason_code(reason: Reason) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

impl From<crate::game_state::Refusal> for ApiProblem {
    fn from(refusal: crate::game_state::Refusal) -> Self {
        let mut problem = Self::new(refusal.reason, refusal.message);
        problem.violations.extend(refusal.violation);
        problem
    }
}

impl IntoResponse for ApiProblem {
    fn into_response(self) -> Response {
        self.render(serde_json::to_vec)
    }
}

/// **A panic answers 500 with the body**, through `CatchPanicLayer`, instead
/// of dropping the connection, which a client would retry as a blip. The
/// panic's words are logged and never sent.
pub(crate) fn panic_response(panic: Box<dyn std::any::Any + Send + 'static>) -> Response {
    let words = panic
        .downcast_ref::<&str>()
        .map(|words| (*words).to_string())
        .or_else(|| panic.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "a panic with no message".to_string());
    tracing::error!(panic = %words, request_id = current_request_id(), "a handler panicked");
    ApiProblem::internal().into_response()
}

/// **axum's own rejections answer with the body.** A malformed JSON body, a
/// missing content type, an unknown route and a wrong method are answered by
/// the framework before a handler runs, in plain text naming serde's
/// internals. This rewrites any error response that is not already
/// `application/problem+json`; the framework's words go to the log at `info`
/// and never to the caller.
pub(crate) async fn rewrite_framework_errors(response: Response) -> Response {
    let status = response.status();
    if !(status.is_client_error() || status.is_server_error()) {
        return response;
    }
    let is_problem = response
        .headers()
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with(PROBLEM_JSON));
    if is_problem {
        return response;
    }
    let (parts, body) = response.into_parts();
    let words = axum::body::to_bytes(body, 4096)
        .await
        .map(|bytes| without_values(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_default();
    let reason = match status.as_u16() {
        400 => Reason::MalformedRequest,
        404 => Reason::NoSuchRoute,
        405 => Reason::MethodNotAllowed,
        413 => Reason::BodyTooLarge,
        415 => Reason::UnsupportedMediaType,
        422 => Reason::InvalidBody,
        _ => Reason::Internal,
    };
    if reason == Reason::Internal {
        tracing::error!(status = status.as_u16(), %words, request_id = current_request_id(), "a response the server did not build; answering 500");
        return ApiProblem::internal().into_response();
    }
    tracing::info!(status = status.as_u16(), %words, request_id = current_request_id(), "the framework refused a request");
    let mut response = framework_problem(reason).into_response();
    // `Allow` on a 405 is the framework's, and a caller can use it.
    if let Some(allow) = parts.headers.get(axum::http::header::ALLOW) {
        response
            .headers_mut()
            .insert(axum::http::header::ALLOW, allow.clone());
    }
    response
}

/// The framework's words, cut before the first quoted value. serde's messages
/// echo what the caller sent (`invalid type: string "…", expected …`), and the
/// log carries identifiers only (docs/4.4.7), so the log keeps the kind of the
/// failure and not the value.
fn without_values(words: &str) -> String {
    let end = words.find(['`', '"']).unwrap_or(words.len());
    words[..end].trim().chars().take(200).collect()
}

/// What each framework refusal says to a caller: never the framework's words.
fn framework_problem(reason: Reason) -> ApiProblem {
    match reason {
        Reason::MalformedRequest => ApiProblem::new(
            Reason::MalformedRequest,
            "The request could not be read. Check it and try again.",
        ),
        Reason::NoSuchRoute => {
            ApiProblem::new(Reason::NoSuchRoute, "There is nothing at that address.")
        }
        Reason::MethodNotAllowed => ApiProblem::new(
            Reason::MethodNotAllowed,
            "That address does not accept this kind of request.",
        ),
        Reason::BodyTooLarge => {
            ApiProblem::new(Reason::BodyTooLarge, "The request body is too large.")
        }
        Reason::UnsupportedMediaType => ApiProblem::new(
            Reason::UnsupportedMediaType,
            "The request body must be sent as application/json.",
        ),
        _ => ApiProblem::new(
            Reason::InvalidBody,
            "The request body is missing a field or has a field of the wrong type.",
        ),
    }
}

#[cfg(test)]
mod database_failures {
    use super::*;

    /// The words `sqlx` uses, measured against a real pool on 2026-09-13 and
    /// recorded on #380. If any of these reaches a caller the leak is back.
    const DRIVER_WORDS: [&str; 6] = [
        "UNIQUE constraint failed",
        "no such table",
        "no such column",
        "NOT NULL constraint failed",
        "syntax error",
        "error returned from database",
    ];

    // **The `Database` variant is not constructed here, and that is a real
    // limit of this test.** It needs a live driver error, which needs a pool —
    // so the classification of SQLite codes 5 and 6 is evidenced by the
    // throwaway measurement recorded on #380 rather than by a unit test. What
    // is covered here is the two things that can be built: a non-transient
    // error must say nothing, and a pool failure must be a 503.

    #[test]
    fn a_database_failure_tells_the_caller_nothing_about_the_schema() {
        let problem = ApiProblem::from_sqlx(sqlx::Error::RowNotFound);
        assert_eq!(problem.status_for_test(), StatusCode::INTERNAL_SERVER_ERROR);
        for word in DRIVER_WORDS {
            assert!(
                !problem.message_for_test().contains(word),
                "the message leaked {word:?}: {}",
                problem.message_for_test()
            );
        }
    }

    /// Load rather than fault. Answering 500 told a client to give up, when the
    /// useful answer is *come back in a moment* — #380 R6.
    #[test]
    fn a_pool_timeout_is_a_503_and_says_when_to_return() {
        let problem = ApiProblem::from_sqlx(sqlx::Error::PoolTimedOut);
        assert_eq!(problem.status_for_test(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(problem.reason_for_test(), Reason::ServiceBusy);

        let closed = ApiProblem::from_sqlx(sqlx::Error::PoolClosed);
        assert_eq!(closed.status_for_test(), StatusCode::SERVICE_UNAVAILABLE);
    }

    /// T17's other half: any database error that is not load answers 500
    /// `INTERNAL`, with the one sentence.
    #[test]
    fn any_other_database_error_is_internal() {
        let problem = ApiProblem::from_sqlx(sqlx::Error::RowNotFound);
        assert_eq!(problem.reason_for_test(), Reason::Internal);
        assert_eq!(problem.message_for_test(), INTERNAL_MESSAGE);
    }

    /// T8: the two database lines carry the request's ID, so a report quoting
    /// the body's `correlation_id` finds them.
    #[tokio::test]
    async fn the_database_lines_carry_the_request_id() {
        let log = crate::app::tests::start_capturing_log_on_this_thread();
        REQUEST_ID
            .scope("7F3K9QWX2M4D".to_string(), async {
                let _ = ApiProblem::from_sqlx(sqlx::Error::PoolTimedOut);
                let _ = ApiProblem::from_sqlx(sqlx::Error::RowNotFound);
            })
            .await;
        let text = log.text();
        for line in ["database unavailable", "database error"] {
            let found = text
                .lines()
                .find(|l| l.contains(line))
                .unwrap_or_else(|| panic!("no {line:?} line in {text}"));
            assert!(found.contains("7F3K9QWX2M4D"), "{found}");
        }
    }

    /// The one failure inside the error path: a body that will not serialise
    /// answers a fixed `application/problem+json` string, which says the same
    /// sentence as every other 500.
    #[tokio::test]
    async fn a_body_that_fails_to_serialise_answers_the_fixed_fallback() {
        let failure = serde_json::from_str::<u8>("not a number").unwrap_err();
        let response =
            ApiProblem::new(Reason::GameNotFound, "Game not found").render(|_| Err(failure));
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(
            response.headers().get("content-type").unwrap(),
            PROBLEM_JSON
        );
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let body: ApiError = serde_json::from_slice(&bytes).expect("the fallback is a valid body");
        assert_eq!(body.reason, Some(Reason::Internal));
        assert_eq!(body.status, 500);
        assert_eq!(body.detail, INTERNAL_MESSAGE);
        assert_eq!(body.message, INTERNAL_MESSAGE);
        assert_eq!(body.error_type, Some(ErrorType::Unexpected));
        assert!(!body.blip);
    }
}
