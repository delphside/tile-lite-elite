use std::net::SocketAddr;

use server_game::email::EmailConfig;
use server_game::{AppState, app_version, build_router};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // RUST_LOG controls verbosity (e.g. `RUST_LOG=debug`, or
    // `RUST_LOG=server_game=debug,tower_http=debug` to scope it) — defaults
    // to `info` for this crate and `warn` for everything else so a plain
    // `docker compose logs` / journal isn't dominated by dependency noise.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "server_game=info,tower_http=info,warn".into()),
        )
        .init();

    let database_url = std::env::var("TILE_LITE_ELITE_DATABASE_URL")
        .unwrap_or_else(|_| "sqlite://data/tile-lite-elite.sqlite3".to_string());
    let bind =
        std::env::var("TILE_LITE_ELITE_BIND").unwrap_or_else(|_| "127.0.0.1:3000".to_string());
    // Only used to build the link inside a password-reset email — see
    // `AppState::public_base_url`'s doc comment. Defaults to the local web
    // dev server so the flow works out of the box in dev without this var
    // set; production sets it explicitly (docker-compose.yml).
    let public_base_url = std::env::var("TILE_LITE_ELITE_PUBLIC_BASE_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    // Unset in local dev by default — every email-triggering flow still
    // works without it, just logging the message instead of sending it
    // (see EmailConfig's doc comment). Production sets both explicitly.
    let email_api_key = std::env::var("RESEND_API_KEY")
        .ok()
        .filter(|key| !key.is_empty());
    let email_from_address = std::env::var("RESEND_FROM_ADDRESS")
        .unwrap_or_else(|_| "Tile Lite Elite <noreply@mail.tileliteelite.com>".to_string());
    let email_config = EmailConfig::new(email_api_key, email_from_address);

    // `--migrate-only`: apply pending migrations and exit, without binding a
    // port or loading any games.
    //
    // Exists so a deploy can find out whether this build's migrations apply
    // to the live database *before* it becomes the live server. Migrations
    // otherwise run as a side effect of startup, which fuses two questions
    // that want separate answers: "does the schema change work" and "does
    // the new version serve traffic". Fused, a failing migration takes the
    // site down — the old container has already been replaced and the new
    // one exits, restarts, exits. Asked separately, the old version is still
    // running and the deploy can simply stop.
    //
    // Safe to run against a database an older server is still using: SQLite
    // wraps each migration in a transaction, so this either completes or
    // leaves nothing behind. `scripts/deploy.sh` stops the server first
    // anyway, so the old code never sees a half-changed schema.
    if std::env::args().any(|arg| arg == "--migrate-only") {
        let pool = server_game::persistence::connect(&database_url).await?;
        let version = server_game::persistence::applied_schema_version(&pool).await?;
        tracing::info!(
            database_url,
            schema_version = version.unwrap_or(0),
            "migrations applied; exiting (--migrate-only)"
        );
        return Ok(());
    }

    let state = AppState::new(&database_url, public_base_url, email_config).await?;
    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind(bind.parse::<SocketAddr>()?).await?;

    tracing::info!(
        %bind,
        database_url,
        app_version = %app_version(),
        api_version = %api::API_VERSION,
        "server-game starting"
    );

    // Build the dictionaries off the request path. Without this the first
    // game created for an edition pays the construction inside its own
    // request — measured at 310ms (sowpods) to 937ms (german) on the
    // production VM, seen by the player as New Game hanging. Detached and
    // blocking-pooled: it is pure CPU, it must not delay the listener, and
    // nothing needs to await it — any request that arrives first simply
    // builds what it needs itself, exactly as before.
    tokio::task::spawn_blocking(|| {
        let started = std::time::Instant::now();
        rules_shared::build_all_dictionaries();
        tracing::info!(
            elapsed_ms = started.elapsed().as_millis() as u64,
            "dictionaries built"
        );
    });

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}
