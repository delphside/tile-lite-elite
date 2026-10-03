use super::*;

/// `Debug` so tests can `.expect()` on a `Result<_, ApiProblem>`; the
/// derive is harmless because both fields are already safe to print (the
/// message is what the client receives, never anything DB-sourced — see
/// `ApiError`'s note in `crates/api`).
#[derive(Debug)]
pub struct ApiProblem {
    status: StatusCode,
    message: String,
    /// Games standing in the way, sent alongside the message so a client can
    /// render them however suits it. Empty for everything except the refusals
    /// that have some to name.
    blocking_games: Vec<api::AdminGameSummaryDto>,
    /// Seconds for a `Retry-After` header, set only on 503. A client that
    /// is told to come back should be told when — without it, a well-behaved
    /// client has to guess, and guessing usually means retrying immediately,
    /// which is the worst thing to do to a server that just said it was full.
    retry_after: Option<u32>,
}

impl ApiProblem {
    pub(crate) fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
    }

    /// A refusal that can name the games responsible. The message still
    /// stands on its own, for a client that does not read the list.
    pub(crate) fn blocked_by_games(
        message: impl Into<String>,
        blocking_games: Vec<api::AdminGameSummaryDto>,
    ) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
            blocking_games,
            retry_after: None,
        }
    }

    pub(crate) fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
    }

    pub(crate) fn unauthorized(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
    }

    pub(crate) fn forbidden(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
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
    /// **So the body says nothing and the detail goes to the log.** Until #71
    /// adds a correlation id to `ApiError` the caller has no id to quote, which
    /// is a known cost accepted on #380: an id in the log with a timestamp is
    /// most of the value, and the leak is reachable today.
    ///
    /// **Transient or not is the other half, and it decides the status.** A
    /// pool timeout, a closed pool and a locked database are load rather than
    /// faults — measured on #380 as `PoolTimedOut`, `PoolClosed` and SQLite
    /// code 5 — so they answer 503 with `Retry-After`, because a client told to
    /// come back should be told when. Everything else is a bug or corruption
    /// and answers 500.
    pub(crate) fn from_sqlx(error: sqlx::Error) -> Self {
        if Self::is_transient(&error) {
            tracing::warn!(%error, "database unavailable — answering 503");
            return Self::unavailable(
                "The service is busy just now. Please try again in a moment.",
                2,
            );
        }
        tracing::error!(%error, "database error");
        Self::internal("Something went wrong. Please try again.")
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
    pub(crate) fn from_sqlx_or_duplicate(error: sqlx::Error, message: &str) -> Self {
        if let sqlx::Error::Database(db) = &error
            && db.is_unique_violation()
        {
            return Self::bad_request(message);
        }
        Self::from_sqlx(error)
    }

    pub(crate) fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
    }

    /// The status this problem will respond with. Test-only: the field is
    /// private so handlers cannot branch on it, but a test asserting 503
    /// rather than 429 is asserting the distinction the codes exist to make.
    #[cfg(test)]
    pub(crate) fn status_for_test(&self) -> StatusCode {
        self.status
    }

    /// Test-only, for the same reason as `status_for_test`: the one thing worth
    /// asserting about a database failure is what the caller is told, and #380
    /// exists because that was the driver's own sentence.
    #[cfg(test)]
    pub(crate) fn message_for_test(&self) -> &str {
        &self.message
    }

    /// The server is at capacity — not the caller's fault, which is why this
    /// is 503 and not 429. A 429 says "you are asking too often"; this says
    /// "everyone together is asking for more expensive work than there is
    /// room for". Keeping them distinct is what lets a log tell an attack
    /// from a genuine capacity shortfall.
    /// The caller is asking too often — their fault, and fixable by them,
    /// which is the whole difference from `unavailable`. Both carry
    /// `Retry-After`, because "wait, then try again" is the useful part of
    /// either answer.
    pub(crate) fn too_many_requests(message: impl Into<String>, retry_after_secs: u32) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: Some(retry_after_secs),
        }
    }

    pub(crate) fn unavailable(message: impl Into<String>, retry_after_secs: u32) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            message: message.into(),
            blocking_games: Vec::new(),
            retry_after: Some(retry_after_secs),
        }
    }
}

impl IntoResponse for ApiProblem {
    fn into_response(self) -> Response {
        let mut response = (
            self.status,
            Json(ApiError {
                message: self.message,
                blocking_games: self.blocking_games,
            }),
        )
            .into_response();
        if let Some(secs) = self.retry_after
            && let Ok(value) = secs.to_string().parse()
        {
            response.headers_mut().insert("retry-after", value);
        }
        response
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

        let closed = ApiProblem::from_sqlx(sqlx::Error::PoolClosed);
        assert_eq!(closed.status_for_test(), StatusCode::SERVICE_UNAVAILABLE);
    }
}
