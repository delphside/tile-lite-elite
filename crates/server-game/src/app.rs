use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use std::net::SocketAddr;

use api::Reason;
use api::{
    AdminGameSummaryDto, AdminResetPasswordRequest, ApiError, ChangePasswordRequest,
    CreateGameRequest, GameActionRequest, GameEventDto, GameInvitationDto, InvitationStatus,
    InvitePlayerRequest, LoginPlayerRequest, PlayerActionDto, PlayerDto, PlayerSessionDto,
    PostChatMessageRequest, PreviewMoveRequest, RegisterPlayerRequest, RequestPasswordResetRequest,
    ResetPasswordRequest, StartGameRequest, SwapSeatsRequest, ValidateSessionRequest,
};
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{ConnectInfo, Path, Query, Request, State, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use sqlx::{Pool, Sqlite};
use tokio::sync::{RwLock, Semaphore, broadcast};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use uuid::Uuid;

use crate::game_state::{
    EngineRegistry, GameSession, ParticipantState, ViewerAccess, attach_invitation_status,
    move_candidate_from_dto, now_unix_seconds, redact_game_state, resolve_viewer_access,
    tile_from_dto,
};
use crate::persistence;
use crate::stats;
use rules_shared::format_move_error;

// Handler modules split out of what was once one ~8.6k-line file. Each
// submodule does `use super::*;` to pull in this module's imports,
// `AppState`, and its sibling handlers/helpers; `build_router` wires them
// together. See docs/1.2-components-and-interactions.md.
mod admin;
mod auth;
mod catalog;
mod common;
pub(crate) mod error;
mod events;
mod games;
mod invitations;
mod metrics;
mod ratings;
mod roster;
mod routes;
mod scheduler;
mod scheduler_jobs;
mod support_mail;
mod sweeps_capacity;
mod sweeps_game;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_account_lifecycle;
#[cfg(test)]
mod tests_errors;
#[cfg(test)]
mod tests_hardening;
#[cfg(test)]
mod tests_metrics;
#[cfg(test)]
mod tests_routes;
mod throttle;

use self::admin::*;
use self::auth::*;
use self::catalog::*;
use self::common::*;
use self::error::*;
use self::events::*;
use self::games::*;
use self::invitations::*;
use self::ratings::*;
use self::roster::*;
use self::sweeps_capacity::*;
use self::sweeps_game::*;

pub use self::scheduler_jobs::spawn_scheduler;
pub use self::support_mail::SupportMailConfig;

#[derive(Clone)]
pub struct AppState {
    pub db: Pool<Sqlite>,
    pub games: Arc<RwLock<HashMap<String, GameSession>>>,
    pub events: broadcast::Sender<GameEventDto>,
    /// The id of each game deleted, by the admin or the sweep, so a WebSocket
    /// open on it can close with 4404 rather than sit silent for a game that
    /// no longer exists.
    pub(crate) deleted_games: broadcast::Sender<String>,
    /// Set when the server begins to stop, so each open WebSocket can say
    /// *going away* (1001) rather than vanish. See `begin_shutdown`.
    pub(crate) shutdown: tokio::sync::watch::Sender<bool>,
    pub engines: EngineRegistry,
    /// Where the web client is actually served from — needed server-side
    /// only for building an absolute link into a password-reset email
    /// (`{public_base_url}/reset-password?token=...`). Everything else the
    /// server does is host-agnostic (see `TILE_LITE_ELITE_API_BASE_URL`'s
    /// own doc comment in `docs/4.1-configuration.md` for why the *client* doesn't
    /// need this baked in), so this field exists solely for that one link.
    pub public_base_url: String,
    pub email: crate::email::EmailConfig,
    /// Captured once, right after migrations run — see
    /// `persistence::applied_schema_version` for why it can't change later
    /// and what the deploy script does with it.
    pub schema_version: Option<i64>,
    /// How many password hashes may run at once.
    ///
    /// Argon2 is deliberately memory-hard — `Argon2::default()` is the OWASP
    /// profile, 19 MiB and two passes per hash — which is the property that
    /// makes stored hashes expensive to attack, and the reason unbounded
    /// concurrency here is dangerous. On the production VM (2 CPUs, ~438 MB
    /// free) roughly 23 simultaneous hashes exhaust memory, and hashing on
    /// the blocking pool would otherwise be bounded only by tokio's default
    /// 512 threads.
    ///
    /// A semaphore rather than a smaller pool: engine search shares that
    /// pool, and each workload wants its own bound. See `engine_limit`.
    pub hash_limit: Arc<Semaphore>,
    /// How many engine move searches may run at once. `run_engine_turns`
    /// already bounds a single search's *duration* with `tokio::time::timeout`,
    /// but nothing bounded how many ran together: ten concurrent games meant
    /// ten blocking threads competing for two cores, and a bot harness (#10)
    /// makes that the normal case rather than the unlucky one.
    pub engine_limit: Arc<Semaphore>,
    /// When each scheduled job (#400) last completed a pass, and how many
    /// items on that pass errored. Empty until `spawn_scheduler` runs a job
    /// for the first time — read by `admin_scheduler_health`, never written
    /// outside `scheduler::run_once`.
    pub(crate) scheduler_health: scheduler::SchedulerHealth,
    /// The service desk's mail poller (`support_mail.rs`). `None` when its
    /// two settings are not both present, and then its job is not scheduled.
    pub(crate) support_mail: Option<Arc<support_mail::SupportMail>>,
    /// What the server has counted of its own symptoms since this state was
    /// made (#402 R3): written by `metrics::count_response`, read by
    /// `admin_metrics`. In the state and not a `static`, so each test has its
    /// own.
    pub(crate) metrics: Arc<metrics::Metrics>,
}

/// Read a concurrency limit from the environment, falling back to a default
/// tuned for the production VM's two cores. Nonsense values fall back rather
/// than failing: a typo in an environment variable should not stop the
/// server booting, and the default is always safe.
fn concurrency_from_env(var: &str, default: usize) -> usize {
    std::env::var(var)
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

impl AppState {
    pub async fn new(
        database_url: &str,
        public_base_url: String,
        email: crate::email::EmailConfig,
    ) -> Result<Self, sqlx::Error> {
        let db = persistence::connect(database_url).await?;
        let schema_version = persistence::applied_schema_version(&db).await?;
        let engines = EngineRegistry::default();
        persistence::upsert_engine_profiles(&db, &engines.metadata()).await?;

        let mut games = HashMap::new();
        for id in persistence::list_game_ids(&db).await? {
            if let Some(game) = persistence::load_game(&db, &id).await? {
                games.insert(id, game);
            }
        }

        let (events, _) = broadcast::channel(64);
        let (deleted_games, _) = broadcast::channel(16);
        let (shutdown, _) = tokio::sync::watch::channel(false);

        // Defaults sized for the production VM: 2 CPUs, ~438 MB free. Four
        // concurrent hashes is ~76 MB and keeps both cores busy without
        // starving anything else; two engine searches match the core count,
        // since a search is pure computation with nothing to overlap.
        let hash_limit = Arc::new(Semaphore::new(concurrency_from_env(
            "TILE_LITE_ELITE_HASH_CONCURRENCY",
            4,
        )));
        let engine_limit = Arc::new(Semaphore::new(concurrency_from_env(
            "TILE_LITE_ELITE_ENGINE_CONCURRENCY",
            2,
        )));

        Ok(Self {
            db,
            games: Arc::new(RwLock::new(games)),
            events,
            deleted_games,
            shutdown,
            engines,
            public_base_url,
            email,
            schema_version,
            hash_limit,
            engine_limit,
            scheduler_health: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
            support_mail: None,
            metrics: Arc::new(metrics::Metrics::new()),
        })
    }

    /// Tells every open WebSocket the server is stopping: each closes with
    /// 1001, *going away*, which a client reads as "reconnect", not as a
    /// failure. `main` calls it when the stop signal arrives. **It then waits
    /// `SHUTDOWN_GRACE`**: the listener's graceful drain waits for ordinary
    /// requests only (hyper does not wait for an upgraded connection, whose
    /// task is the application's), so without the wait the process could exit
    /// before a socket had written its close frame.
    pub async fn begin_shutdown(&self) {
        let _ = self.shutdown.send(true);
        tokio::time::sleep(events::SHUTDOWN_GRACE).await;
    }

    /// Switches the support-mail poller on when `main.rs` found its settings.
    /// A method rather than an `AppState::new` argument, so the tests that
    /// build a state without it need not name it.
    pub fn with_support_mail(mut self, config: Option<SupportMailConfig>) -> Self {
        self.support_mail = config.map(|config| Arc::new(support_mail::SupportMail::new(config)));
        self
    }
}

pub fn build_router(state: AppState) -> Router {
    build_router_with(state, Router::new())
}

/// `build_router`, with `extra` routes merged in before the layers go on, so a
/// test can add a route that panics or answers oddly and meet the same
/// middleware production does. Production passes none.
fn build_router_with(state: AppState, extra: Router<AppState>) -> Router {
    use routes::{Access, Limit};

    // Every route is registered from `routes::all`, where it declares who may
    // call it and which limiter it sits behind; this only assembles the tiers.
    //
    // Admin is outside every limiter: it is loopback-only, so the only caller
    // is the operator, and throttling them mid-cleanup helps nobody. The guard
    // enforces that whatever TILE_LITE_ELITE_BIND is set to
    // (docs/3.2-development.md documents binding to 0.0.0.0 for LAN play,
    // which would otherwise expose these to the whole LAN too).
    let admin_routes = routes::router(|route| route.access == Access::Loopback)
        .layer(middleware::from_fn(require_loopback));

    let registration_routes =
        throttle::registration(routes::router(|route| route.limit == Limit::Registration));
    let heavy_auth_routes =
        throttle::heavy_auth(routes::router(|route| route.limit == Limit::HeavyAuth));
    let player_routes = routes::router(|route| route.limit == Limit::Authenticated);

    // Everything a caller does once signed in, keyed by session, then a floor
    // under the lot.
    let limited = throttle::global(
        registration_routes
            .merge(heavy_auth_routes)
            .merge(throttle::authenticated(player_routes)),
    );

    // `/health`, with no limit of any kind: a health check that fails under
    // load reports an outage that is not happening, and the deploy would roll
    // back a release that was merely busy.
    let unlimited =
        routes::router(|route| route.limit == Limit::Unlimited && route.access != Access::Loopback);

    Router::new()
        .merge(unlimited)
        .merge(limited)
        .merge(admin_routes)
        .merge(extra)
        // **Every response is a result** (docs/1.10): axum's own rejections are
        // rewritten into the Problem Details body, innermost so that a handler's
        // own `ApiProblem` is left as it is, and a panic answers 500 with the
        // body instead of dropping the connection, which a client would retry
        // as a blip.
        .layer(middleware::map_response(rewrite_framework_errors))
        .layer(tower_http::catch_panic::CatchPanicLayer::custom(
            panic_response,
        ))
        .layer(CorsLayer::permissive())
        // Every response says which build produced it, so a client can notice
        // that the server has moved without asking a question of its own. It
        // is a header rather than a body field because it belongs to *any*
        // response, not to one endpoint: putting it in `/health` would mean
        // clients polling `/health` on a timer to learn about an event that
        // happens a few times a week.
        //
        // A client compares this against its own build id and, if they differ,
        // confirms against `/version.txt` before reloading — that file is
        // served alongside the bundle, so it knows what is *actually* being
        // served, which this header cannot. See docs/3.3 and `crates/ui`'s
        // `note_server_build`.
        //
        // Omitted entirely on a build with no id (a local `cargo run`), since
        // "I cannot tell you" is better said by silence than by a value that
        // never changes.
        .layer(build_id_header())
        // One INFO-level span per request (method, path, status, latency)
        // with no per-handler code — this alone covers "what happened and
        // when" for the whole HTTP surface; the tracing calls sprinkled
        // through individual handlers below are for the *why* on top of it
        // (which player, which game, why a request was rejected).
        .layer(TraceLayer::new_for_http())
        // Counts the response the caller will see: outside the panic layer and
        // the rewrite, so a panic's 500, axum's rewritten 400 and a CORS
        // preflight's answer are all counted, and inside the request ID, which
        // it does not need (#402 R3).
        .layer(middleware::from_fn_with_state(
            state.metrics.clone(),
            metrics::count_response,
        ))
        // Outermost, so that every layer above and every response, a CORS
        // preflight and a panic's 500 included, runs inside the request's ID.
        .layer(middleware::from_fn(request_id_layer))
        .with_state(state)
}

/// The build this server was compiled from — the same id `app_version` appends,
/// on its own rather than with the release number, because what a client needs
/// is "is this the code I have", and the id answers that exactly.
pub(crate) const BUILD_ID: Option<&str> = option_env!("TILE_LITE_ELITE_BUILD_ID");

/// Stamps `x-build-id` on every response. `Option` so an unidentified build
/// sets no header at all rather than a misleading constant.
fn build_id_header()
-> tower_http::set_header::SetResponseHeaderLayer<Option<axum::http::HeaderValue>> {
    build_id_header_for(BUILD_ID)
}

/// Split from `build_id_header` so the behaviour can be tested. `BUILD_ID` is
/// fixed at compile time and unset under `cargo test`, so a test that went
/// through it could only ever observe the empty case — which is the half that
/// matters least.
fn build_id_header_for(
    id: Option<&str>,
) -> tower_http::set_header::SetResponseHeaderLayer<Option<axum::http::HeaderValue>> {
    tower_http::set_header::SetResponseHeaderLayer::overriding(
        axum::http::HeaderName::from_static("x-build-id"),
        match id {
            Some(id) if !id.is_empty() => axum::http::HeaderValue::from_str(id).ok(),
            _ => None,
        },
    )
}

/// The `Major.Minor.Patch` release version from Cargo.toml, plus an
/// optional build identifier appended as SemVer build metadata (`+<id>`)
/// when `TILE_LITE_ELITE_BUILD_ID` is set at compile time — e.g. a git short
/// SHA or CI run number, for telling internal/test builds apart. A
/// production release simply doesn't set that var, so it shows only the
/// three numbers. Distinct from `api::API_VERSION`: this is the build
/// identity, not the wire-contract version clients check on connect.
/// Logged at startup (`main.rs`) and served at `/health` — the latter is
/// what lets `scripts/deploy-preview.sh at prod` find out which commit is
/// actually live without SSHing in.
pub fn app_version() -> String {
    format_app_version(
        env!("CARGO_PKG_VERSION"),
        option_env!("TILE_LITE_ELITE_BUILD_ID"),
    )
}

fn format_app_version(pkg_version: &str, build_id: Option<&str>) -> String {
    match build_id {
        Some(id) if !id.is_empty() => format!("{pkg_version}+{id}"),
        _ => pkg_version.to_string(),
    }
}
