//! Rate limiting: how often a caller may ask.
//!
//! Distinct from the concurrency bounds already in place. A semaphore limits
//! how much expensive work runs *at once*, which is what stops the server
//! falling over; nothing yet limits how *often* anyone asks, so a caller can
//! queue without limit — memory stays bounded at four hashes while the queue
//! does not, and everybody else waits behind it.
//!
//! Four layers, applied outermost first, each answering a different question:
//!
//! | layer | key | question |
//! | --- | --- | --- |
//! | registration | client address | is one source manufacturing accounts |
//! | heavy auth | client address | is one source burning Argon2 time |
//! | authenticated | session token | is one caller monopolising the service |
//! | global | none | is the service as a whole beyond its means |
//!
//! `/health` carries none of them. Monitoring and `deploy.sh`'s own smoke test
//! call it, and it has to answer while everything else is refusing — a health
//! check that fails under load reports an outage that is not happening, and
//! `deploy.sh` would roll back a release that was merely busy.
//!
//! This is not prevention. Registration is open, so a determined caller can
//! spread across addresses and accounts. It buys a cost per attempt and a
//! decent error instead of a growing queue; bad behaviour is dealt with by
//! stopping the account behind it.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use axum::extract::ConnectInfo;
use axum::http::Request;
use rand::Rng;
use tower_governor::governor::GovernorConfigBuilder;
use tower_governor::key_extractor::KeyExtractor;
use tower_governor::{GovernorError, GovernorLayer};

use axum::response::IntoResponse;

use super::error::ApiProblem;

use super::AppState;
use axum::Router;

/// Requests a minute, read from the environment so the numbers can be retuned
/// on the rehearsal host without a rebuild. The defaults are a first guess for
/// a 2 vCPU, 954 MB box.
///
/// An *empty* value falls back to the default as an unset one does, which
/// matters because Compose passes `${VAR:-}` through as an empty string rather
/// than omitting it. Caddy's `{$VAR:default}` does the opposite and took a
/// deploy down over it; the parse here fails on an empty string, so both cases
/// land on the default.
fn limit_from_env(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

/// The burst allowed on top of the rate, tunable for the same reason: it is
/// what decides whether an ordinary caller ever meets the limit at all. A
/// rate without a burst refuses the second of two clicks.
fn burst_from_env(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

/// The caller's address, taken from `X-Forwarded-For` when it is there and
/// the socket's peer otherwise.
///
/// **This trusts a header, and may only do so while the server has no port of
/// its own.** `docker-compose.yml` gives the `server` service no `ports:`, so
/// Caddy is the sole ingress and the header is Caddy's. The moment anything
/// else can reach the server, the header is attacker-controlled and this
/// becomes a way to evade the limit — or, worse, to lock out a chosen victim
/// by forging their address.
///
/// Without it the key would be the `web` container for every request on the
/// internet, which is worse than no limit at all: the first abuser locks out
/// everyone.
#[derive(Clone)]
pub struct ClientAddress;

impl KeyExtractor for ClientAddress {
    type Key = IpAddr;

    fn extract<T>(&self, request: &Request<T>) -> Result<Self::Key, GovernorError> {
        if let Some(forwarded) = request
            .headers()
            .get("x-forwarded-for")
            .and_then(|value| value.to_str().ok())
            // Left-most is the original client; Caddy appends, so anything
            // after the first entry is a proxy in the chain.
            .and_then(|value| value.split(',').next())
            .map(str::trim)
            .and_then(|value| value.parse::<IpAddr>().ok())
        {
            return Ok(forwarded);
        }

        Ok(request
            .extensions()
            .get::<ConnectInfo<SocketAddr>>()
            .map(|ConnectInfo(address)| address.ip())
            // A request with neither header nor peer address is an in-process
            // test. Give them all one bucket rather than refusing: the tests
            // that care set one of the two.
            .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED)))
    }
}

/// The session token, for callers who have one.
///
/// Per session rather than per account, because resolving a token to an
/// account needs the database and a key extractor cannot wait. In practice
/// they coincide for the case that matters: a bot harness reuses one session
/// rather than authenticating per move, so its traffic keys to one bucket and
/// can be reasoned about on its own.
///
/// A caller with several devices gets an allowance each, which is the right
/// answer for a person and a tolerable one for anybody else — logging in
/// again to buy a fresh allowance has to pass the heavy-auth limit first, so
/// the loop costs more than it yields.
///
/// Falls back to the address, so an unauthenticated caller on these routes is
/// still keyed to something.
#[derive(Clone)]
pub struct SessionOrAddress;

impl KeyExtractor for SessionOrAddress {
    type Key = String;

    fn extract<T>(&self, request: &Request<T>) -> Result<Self::Key, GovernorError> {
        if let Some(token) = request
            .headers()
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .map(str::trim)
            .filter(|token| !token.is_empty())
        {
            return Ok(format!("session:{token}"));
        }
        Ok(format!("address:{:?}", ClientAddress.extract(request)?))
    }
}

/// Every seat at once: no key, so one bucket for the whole service.
#[derive(Clone)]
pub struct Everything;

impl KeyExtractor for Everything {
    type Key = ();

    fn extract<T>(&self, _request: &Request<T>) -> Result<Self::Key, GovernorError> {
        Ok(())
    }
}

/// Applies a limit of `per_minute` requests a minute, with a burst of `burst`
/// on top.
///
/// `governor` replenishes one permit every period rather than clearing the
/// bucket on the minute, so a caller that stays under the rate is never
/// refused and one that exceeds it is slowed rather than locked out for the
/// rest of a window.
///
/// The layer is applied here rather than returned because its type names a
/// middleware `tower_governor` does not export, and inference sidesteps that
/// without a dependency on `governor` for one type name.
fn apply<K>(router: Router<AppState>, key: K, per_minute: u64, burst: u32) -> Router<AppState>
where
    K: KeyExtractor + Send + Sync + 'static,
    K::Key: Send + Sync,
{
    // Off under `cfg(test)`. The in-process suite shares one bucket — no
    // forwarded header, no peer address — so a test registering six players
    // would meet the registration limit, and the whole binary would meet the
    // global one. The limits are then ambient conditions of every test rather
    // than the subject of any, which is how a suite starts failing for
    // reasons unrelated to what it asserts.
    //
    // The limiter is tested directly instead, below, against a router built
    // for the purpose with the numbers written down in the test.
    if cfg!(test) {
        return router;
    }

    let config = GovernorConfigBuilder::default()
        .period(period_for(per_minute))
        .burst_size(burst)
        .key_extractor(key)
        .finish()
        .expect("a positive period and burst make a valid governor config");
    router.layer(
        GovernorLayer::new(std::sync::Arc::new(config)).error_handler(|error| {
            refusal(error, |wait| {
                ApiProblem::too_many_requests("You are asking too often — please slow down.", wait)
            })
        }),
    )
}

/// Both families answer in the shape every other error uses: an `ApiError`
/// body and a `Retry-After`. Left to itself `tower_governor` writes its own
/// plain-text body, which a client parsing `ApiError` cannot read — so a limit
/// would arrive as "something went wrong" rather than as the one thing the
/// caller could act on.
fn refusal(error: GovernorError, problem: impl Fn(u32) -> ApiProblem) -> axum::response::Response {
    match error {
        GovernorError::TooManyRequests { wait_time, .. } => {
            problem(retry_after(wait_time)).into_response()
        }
        other => ApiProblem::internal(format!("rate limiting failed: {other}")).into_response(),
    }
}

/// How much extra, at most, a caller is asked to wait so that everybody
/// refused at once does not come back at once. See `retry_after`.
const RETRY_JITTER_SECONDS: u64 = 2;

/// What goes in `Retry-After`, from the remaining wait `governor` reports.
///
/// `Retry-After` is machine-readable. Our own client only renders it, but a
/// third-party client — or the bot harness — will use it to schedule a retry,
/// so it has to be a number that works when obeyed exactly.
///
/// Two adjustments, both upward, because the errors are not symmetric: a
/// caller who waits slightly too long is served, and one who waits slightly
/// too little is refused.
///
/// **Round up.** `tower_governor` computes the wait as
/// `wait_time_from(now).as_secs()`, which truncates. The wait is a countdown
/// from the moment of refusal, so it is almost never a whole number of
/// seconds, and 2.99s was reported as 2 — a client obeying it exactly was
/// refused again, every time. The value arrives already truncated, so adding
/// one is the ceiling. This subsumes the old `.max(1)`: a sub-second wait
/// still reports 1, and zero is never offered, since zero invites the
/// immediate retry a limited caller should not make.
///
/// Shared with `auth::with_hash_permit`, which refuses for a different reason
/// and needs the same treatment: a full hashing pool refuses callers who are
/// hashing *at the same moment*, so they are simultaneous by definition and
/// would otherwise all be told the same number. One implementation rather than
/// two, because two would drift.
///
/// **Then jitter.** The three keyed tiers stagger themselves — each caller's
/// bucket refreshes from its own spend — but `global` is one bucket for the
/// whole service, with a 50ms period, so every caller it refuses computes the
/// same sub-second wait and is told the same number. Without jitter they all
/// return together, into a service that was already short of room. Rounding up
/// on its own would make that worse, by turning a spread of truncated values
/// into a uniform one.
pub(crate) fn retry_after(wait_time: u64) -> u32 {
    let seconds = wait_time
        .saturating_add(1)
        .saturating_add(rand::thread_rng().gen_range(0..=RETRY_JITTER_SECONDS));
    u32::try_from(seconds).unwrap_or(u32::MAX)
}

/// One permit every this often. Shared so the keyed tiers and the global floor
/// cannot drift apart in how they read their numbers — the config itself is
/// built twice because naming its type would mean depending on `governor`
/// directly for one type name.
fn period_for(per_minute: u64) -> std::time::Duration {
    std::time::Duration::from_millis(60_000 / per_minute.max(1))
}

/// Creating accounts, keyed by address. The tightest of the four: a throwaway
/// account is how every other limit here gets worked around, and nobody
/// legitimately registers twice in a minute.
pub fn registration(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        ClientAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_REGISTER_PER_MIN", 2),
        burst_from_env("TILE_LITE_ELITE_LIMIT_REGISTER_BURST", 3),
    )
}

/// Logging in, and the password-reset pair. Each spends ~47 ms of Argon2 on a
/// 2 vCPU box, so the cost is real whether or not the credentials are. Loose
/// enough for somebody mistyping a password, tight enough that guessing is
/// not worth attempting from one address.
pub fn heavy_auth(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        ClientAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_AUTH_PER_MIN", 10),
        burst_from_env("TILE_LITE_ELITE_LIMIT_AUTH_BURST", 10),
    )
}

/// Everything a signed-in caller does. Generous, because a person playing
/// normally must never meet it and a client refreshing its games list every
/// ten seconds is ordinary traffic.
pub fn authenticated(router: Router<AppState>) -> Router<AppState> {
    apply(
        router,
        SessionOrAddress,
        limit_from_env("TILE_LITE_ELITE_LIMIT_SESSION_PER_MIN", 240),
        burst_from_env("TILE_LITE_ELITE_LIMIT_SESSION_BURST", 60),
    )
}

/// A floor under the service as a whole, after the keyed limits have had
/// their say. Catches what spreads across addresses and accounts, which the
/// others by construction cannot.
///
/// **Refuses with 503, not 429**, unlike the three keyed tiers. A caller who
/// meets this one has done nothing wrong — everybody together is asking for
/// more than there is room for — and the two answers mean different things to
/// whoever reads them. `ApiProblem::unavailable` makes the same distinction
/// for the hashing semaphore, and a log that cannot tell an attack from a
/// capacity shortfall is worth less than one that can.
pub fn global(router: Router<AppState>) -> Router<AppState> {
    let per_minute = limit_from_env("TILE_LITE_ELITE_LIMIT_GLOBAL_PER_MIN", 1_200);
    let burst = burst_from_env("TILE_LITE_ELITE_LIMIT_GLOBAL_BURST", 200);

    if cfg!(test) {
        return router;
    }

    let config = GovernorConfigBuilder::default()
        .period(period_for(per_minute))
        .burst_size(burst)
        .key_extractor(Everything)
        .finish()
        .expect("a positive period and burst make a valid governor config");
    router.layer(
        GovernorLayer::new(std::sync::Arc::new(config)).error_handler(|error| {
            refusal(error, |wait| {
                ApiProblem::unavailable("The server is busy — please try again.", wait)
            })
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use axum::routing::get;
    use tower::util::ServiceExt;

    fn forwarded(address: &str) -> Request<Body> {
        Request::builder()
            .uri("/")
            .header("x-forwarded-for", address)
            .body(Body::empty())
            .expect("request should build")
    }

    /// The key is the caller Caddy reports, not the proxy that relayed it —
    /// otherwise every request on the internet shares one bucket and the
    /// first abuser locks out everyone.
    #[test]
    fn the_key_is_the_forwarded_client_not_the_proxy() {
        let key = ClientAddress
            .extract(&forwarded("203.0.113.7"))
            .expect("a forwarded address should extract");
        assert_eq!(key.to_string(), "203.0.113.7");
    }

    /// Caddy appends, so a request that has crossed two proxies lists the
    /// original client first.
    #[test]
    fn the_leftmost_forwarded_address_wins() {
        let key = ClientAddress
            .extract(&forwarded("203.0.113.7, 198.51.100.2"))
            .expect("a chain should extract");
        assert_eq!(key.to_string(), "203.0.113.7");
    }

    /// Two people behind one address share a bucket; two sessions do not.
    /// That is the whole reason the authenticated tier keys on the session —
    /// a bot harness and its owner are one address and two callers.
    #[test]
    fn sessions_are_keyed_apart_even_from_one_address() {
        let with_token = |token: &str| {
            Request::builder()
                .uri("/")
                .header("x-forwarded-for", "203.0.113.7")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .expect("request should build")
        };
        let one = SessionOrAddress
            .extract(&with_token("aaa"))
            .expect("a token should extract");
        let two = SessionOrAddress
            .extract(&with_token("bbb"))
            .expect("a token should extract");
        assert_ne!(one, two, "two sessions are two callers");

        let anonymous = SessionOrAddress
            .extract(&forwarded("203.0.113.7"))
            .expect("an address should extract");
        assert_ne!(
            anonymous, one,
            "and somebody with no session is a third, not folded in with them"
        );
    }

    /// A caller over its allowance is refused rather than queued, which is the
    /// point: the queue is what the concurrency bounds cannot protect.
    #[tokio::test]
    async fn a_caller_over_the_allowance_is_refused() {
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_secs(60))
            .burst_size(2)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(GovernorLayer::new(std::sync::Arc::new(config)));

        let mut statuses = Vec::new();
        for _ in 0..4 {
            let response = app
                .clone()
                .oneshot(forwarded("203.0.113.7"))
                .await
                .expect("the router should answer");
            statuses.push(response.status());
        }

        assert_eq!(
            statuses[0],
            StatusCode::OK,
            "the first request is within the burst"
        );
        assert_eq!(statuses[1], StatusCode::OK, "and so is the second");
        assert_eq!(
            statuses[3],
            StatusCode::TOO_MANY_REQUESTS,
            "the fourth is over it, and is told so rather than made to wait: {statuses:?}"
        );
    }

    /// `Retry-After` has to work when a machine obeys it exactly.
    ///
    /// The bound that matters is the lower one: the value must never be less
    /// than the wait `governor` reported, because that value is already
    /// truncated and acting on it early is the defect this covers. The upper
    /// bound pins the jitter as a spread rather than an open-ended delay.
    #[test]
    fn retry_after_is_never_early_and_never_wildly_late() {
        for wait in [0, 1, 2, 29, 3_600] {
            for _ in 0..50 {
                let answer = u64::from(retry_after(wait));
                let earliest = wait + 1;
                assert!(
                    answer >= earliest,
                    "told to wait {answer}s when governor's own remaining wait was {wait}s, \
                     already truncated — obeying that is too early"
                );
                assert!(
                    answer <= earliest + RETRY_JITTER_SECONDS,
                    "told to wait {answer}s for a {wait}s wait, which is more than jitter allows"
                );
            }
        }
    }

    /// Never zero, whatever the wait. Zero invites the immediate retry a
    /// limited caller should not make, and it was the one case the old
    /// `.max(1)` existed for — worth keeping asserted now that the flooring is
    /// a consequence of rounding up rather than its own step.
    #[test]
    fn retry_after_never_invites_an_immediate_retry() {
        for _ in 0..50 {
            assert!(retry_after(0) >= 1);
        }
    }

    /// The behaviour the rounding is for: a client that waits exactly as long
    /// as it was told is served.
    ///
    /// Before this, `Retry-After` was `wait_time_from(now).as_secs()` —
    /// truncated — so a 3s period reported 2, and obeying it exactly was
    /// refused every time. A test asserting only that a caller recovers
    /// *eventually* passed throughout.
    ///
    /// Built with the real `refusal` handler rather than governor's default
    /// response, because the header under test is the one our handler writes.
    #[tokio::test]
    async fn a_caller_that_obeys_retry_after_is_served() {
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_millis(3000))
            .burst_size(1)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new().route("/", get(|| async { "ok" })).layer(
            GovernorLayer::new(std::sync::Arc::new(config)).error_handler(|error| {
                refusal(error, |wait| {
                    ApiProblem::too_many_requests("too often", wait)
                })
            }),
        );
        let call = async |app: Router| {
            app.oneshot(forwarded("203.0.113.12"))
                .await
                .expect("the router should answer")
        };

        assert_eq!(
            call(app.clone()).await.status(),
            StatusCode::OK,
            "the burst"
        );

        let refused = call(app.clone()).await;
        assert_eq!(refused.status(), StatusCode::TOO_MANY_REQUESTS);
        let told: u64 = refused
            .headers()
            .get("retry-after")
            .expect("a refusal carries Retry-After")
            .to_str()
            .expect("an ASCII header")
            .parse()
            .expect("a whole number of seconds");

        tokio::time::sleep(std::time::Duration::from_secs(told)).await;

        assert_eq!(
            call(app).await.status(),
            StatusCode::OK,
            "waiting exactly as long as Retry-After said must be enough"
        );
    }

    /// Being over the limit slows a caller; it does not shut them out for the
    /// rest of a window. `governor` replenishes one permit per period, so a
    /// caller who waits one out is served again — which is what makes the
    /// limits safe to set low enough to matter. A fixed-window limiter would
    /// pass every other test here and fail this one.
    #[tokio::test]
    async fn a_refused_caller_recovers_after_one_period() {
        // 20ms per permit, so the wait is a test's worth of time rather than a
        // minute's. The behaviour under test is the replenishment, not the rate.
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_millis(20))
            .burst_size(1)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(GovernorLayer::new(std::sync::Arc::new(config)));

        let call = async |app: Router| {
            app.oneshot(forwarded("203.0.113.7"))
                .await
                .expect("the router should answer")
                .status()
        };

        assert_eq!(call(app.clone()).await, StatusCode::OK, "the burst");
        assert_eq!(
            call(app.clone()).await,
            StatusCode::TOO_MANY_REQUESTS,
            "and immediately over it"
        );

        tokio::time::sleep(std::time::Duration::from_millis(60)).await;

        assert_eq!(
            call(app).await,
            StatusCode::OK,
            "a permit replenishes, so the caller is slowed rather than locked out"
        );
    }

    /// The limits are read from the environment so they can be retuned on the
    /// rehearsal host without a rebuild. Every way of not setting one has to
    /// land on the default, and the case that matters most is the empty
    /// string: Compose passes `${VAR:-}` through as `""` rather than omitting
    /// it, which is the opposite of Caddy's `{$VAR:default}` and has already
    /// taken a deploy down once.
    #[test]
    fn an_unusable_limit_falls_back_to_the_default() {
        // Named for this test alone: the process environment is shared with
        // every other test in the binary.
        let name = "TILE_LITE_ELITE_TEST_LIMIT_FALLBACK";
        let cases = [
            (None, "unset"),
            (Some(""), "empty, as Compose passes an unset variable"),
            (Some("   "), "whitespace"),
            (Some("not-a-number"), "not a number"),
            (Some("0"), "zero, which would refuse everything"),
            (Some("-5"), "negative"),
        ];
        for (value, why) in cases {
            match value {
                // SAFETY: single-threaded test, and the variable is unique to it.
                Some(raw) => unsafe { std::env::set_var(name, raw) },
                None => unsafe { std::env::remove_var(name) },
            }
            assert_eq!(limit_from_env(name, 7), 7, "{why} should give the default");
            assert_eq!(burst_from_env(name, 3), 3, "{why} should give the default");
        }

        // SAFETY: as above.
        unsafe { std::env::set_var(name, "42") };
        assert_eq!(limit_from_env(name, 7), 42, "a real number is used");
        assert_eq!(burst_from_env(name, 3), 42, "and so is a real burst");
        // SAFETY: as above.
        unsafe { std::env::remove_var(name) };
    }

    /// One caller's allowance is their own — a busy neighbour must not be
    /// able to lock somebody else out.
    #[tokio::test]
    async fn one_callers_allowance_is_not_anothers() {
        let config = GovernorConfigBuilder::default()
            .period(std::time::Duration::from_secs(60))
            .burst_size(1)
            .key_extractor(ClientAddress)
            .finish()
            .expect("a valid config");
        let app = Router::new()
            .route("/", get(|| async { "ok" }))
            .layer(GovernorLayer::new(std::sync::Arc::new(config)));

        for _ in 0..3 {
            let _ = app.clone().oneshot(forwarded("203.0.113.7")).await;
        }
        let other = app
            .clone()
            .oneshot(forwarded("198.51.100.9"))
            .await
            .expect("the router should answer");
        assert_eq!(
            other.status(),
            StatusCode::OK,
            "a different address starts with its own allowance"
        );
    }
}
