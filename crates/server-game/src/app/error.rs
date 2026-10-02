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

    pub(crate) fn from_sqlx(error: sqlx::Error) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: error.to_string(),
            blocking_games: Vec::new(),
            retry_after: None,
        }
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
