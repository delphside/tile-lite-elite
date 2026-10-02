# syntax=docker/dockerfile:1

# Single Dockerfile, multiple final targets — `runtime-server` and
# `runtime-web` both build from the same `builder` stage so Docker only
# compiles the workspace once. Select which one to build with `--target`
# (docker-compose.yml does this per service).

FROM rust:1-bookworm AS builder
WORKDIR /workspace

# dioxus-cli version pinned to match crates/ui's `dioxus`/`dioxus-web` deps
# (0.6.3) — a mismatched dx/wasm-bindgen version is a known source of wasm
# build failures in this project (see docs/operations.md). wasm-bindgen-cli
# itself must match the `wasm-bindgen` crate version pinned in Cargo.lock —
# `dx build` doesn't provision this automatically, so it's installed
# explicitly rather than left implicit.
RUN rustup target add wasm32-unknown-unknown \
    && cargo install dioxus-cli --version 0.6.3 --locked \
    && cargo install wasm-bindgen-cli --version 0.2.103 --locked

# .cargo/config.toml sets required wasm32 rustflags
# (target-feature=+reference-types,+multivalue) that wasm-bindgen needs to
# process the compiled binary — dropping this file breaks the wasm build
# with a misleading "failed to read file" error, not an obvious one. It also
# sets `rustc-wrapper = sccache` for fast local rebuilds, which doesn't
# exist in this image; RUSTC_WRAPPER="" below overrides that (env vars take
# precedence over the config file), matching what scripts/services.sh does
# for local wasm dev builds.
COPY .cargo ./.cargo
ENV RUSTC_WRAPPER=""

# Workspace manifests first, so dependency compilation is cached across
# rebuilds that only touch application code. old-crates/{first-try,
# second-try} are workspace members (Cargo needs their manifests present to
# load the workspace), but nothing built here depends on them. Their only
# non-crates.io dependency, `srm-utils`, is a git dependency
# (github.com/SteveStyle/utils, pinned by rev in Cargo.lock) that Cargo
# fetches over the network like any crates.io dependency — no local
# `../utils` checkout or stub crate is needed. old-crates themselves are
# never compiled: the build below is scoped to server-game/admin-cli plus
# the wasm UI.
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY old-crates ./old-crates

# Baked into both binaries via `option_env!` (see each crate's
# `app_version()`) as SemVer build metadata, e.g. `0.2.0+a1c9f02`. Passed
# through from docker-compose.yml's `build.args`, which scripts/deploy.sh
# sets to the current git short SHA — see docs/operations.md's
# "Versioning" section. Placed just before the two build steps below
# rather than at the top of the stage, so a rebuild of the same commit
# (same ARG value) still hits Docker's layer cache.
ARG TILE_LITE_ELITE_BUILD_ID
ENV TILE_LITE_ELITE_BUILD_ID=${TILE_LITE_ELITE_BUILD_ID}

RUN cargo build --release -p server-game -p admin-cli

# Built with an empty API base URL baked in — the client then talks to
# whatever origin it was served from (see `websocket_url` /
# `RootApp`'s `server_url` in crates/ui/src/app.rs), which is what lets one
# wasm build work behind the Caddy reverse proxy regardless of the host's
# actual IP or domain, with no rebuild needed if that changes.
RUN cd crates/ui && CARGO_INCREMENTAL=0 TILE_LITE_ELITE_API_BASE_URL="" dx build --platform web --release

# Identifies the bundle in /srv by its *contents* — a hash of every file dx
# produced. An already-running tab fetches this to decide whether reloading
# would land it on different code; see `watch_for_new_bundle` in
# crates/ui/src/app.rs.
#
# Contents rather than a version number, so it changes when the client
# changes and not otherwise. The workspace version moves on every deploy
# (deploy.sh bumps the patch), so using it here would reload every open tab
# after a server-only release — 0.4.16 changed `games.rs` alone and left
# `crates/ui` untouched, and nobody needed to reload for it. This also keeps
# the signal off `API_VERSION`, which is a statement about the wire contract
# and has no business moving because a button was fixed.
#
# It has to come from the *web* container rather than /health, because the
# one moment it matters is the deploy window where the new server is already
# up and this container still serves the old bundle; /health would report the
# new version and send the tab into a reload loop against unchanged code.
#
# It holds the **build id** — the commit — rather than a hash of the bundle.
# A hash was the same information the long way round: it only ever changed
# because the build id is compiled into the wasm, so it was an indirection over
# the commit that could not tell you which commit it meant. The id can, which
# lets a tab compare three things it now knows — its own build, this
# container's, and the server's — and tell "a deploy is in flight" apart from
# "there is new code for me".
#
# Written only when there is an id to write. A dev build sets no
# TILE_LITE_ELITE_BUILD_ID, and no file is better than an empty one: Caddy's
# SPA fallback answers the missing path with index.html, which the client
# already rejects as unreadable and correctly treats as "cannot tell".
RUN BUNDLE_DIR=target/dx/tile-lite-elite-ui/release/web/public \
    && if [ -n "$TILE_LITE_ELITE_BUILD_ID" ]; then \
        printf '%s' "$TILE_LITE_ELITE_BUILD_ID" > "$BUNDLE_DIR/version.txt" \
        && echo "build id: $TILE_LITE_ELITE_BUILD_ID"; \
    else \
        echo "no build id set — writing no version.txt, so clients will not auto-update"; \
    fi

# ---------------------------------------------------------------------------

FROM debian:bookworm-slim AS runtime-server
# curl is otherwise unused here — pulled in solely so HEALTHCHECK below has
# something to hit /health with, without reaching for a heavier base image.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data

COPY --from=builder /workspace/target/release/server-game /usr/local/bin/server-game
COPY --from=builder /workspace/target/release/tile-lite-elite-admin /usr/local/bin/tile-lite-elite-admin

# Not published by docker-compose.yml — reachable only from the `web`
# (Caddy) container over the compose network. `tile-lite-elite-admin` is run via
# `docker compose exec server tile-lite-elite-admin ...`, which is a genuinely
# loopback connection from inside this container, satisfying the server's
# existing loopback-only guard on /admin/* without weakening it.
EXPOSE 3000
# Gives `docker compose ps`/orchestration a real "unhealthy" signal instead
# of only "still running" — a hung server (e.g. deadlocked on the DB pool)
# would otherwise look identical to a working one until a request failed.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD curl -f http://localhost:3000/health || exit 1
ENTRYPOINT ["/usr/local/bin/server-game"]

# ---------------------------------------------------------------------------

FROM caddy:2-alpine AS runtime-web
COPY --from=builder /workspace/target/dx/tile-lite-elite-ui/release/web/public /srv
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 80
# NOT going through the public :80/:443 site — verified live against
# production that a bare loopback probe there fails: Caddy's global
# HTTP->HTTPS auto-redirect fires for any Host on :80, including one that
# matches none of the configured hostnames, and the TLS handshake on :443
# then fails (no cert for that SNI). Preview's Caddyfile.preview has no
# TLS/redirect at all, so this bug only showed up once actually deployed
# to production — a real lesson in why "verified" means checked against
# the environment that actually differs, not just checked anywhere.
# Caddy's admin API is the reliable signal instead: alive + config loaded.
# Must be 127.0.0.1, not localhost — the admin listener is IPv4-only, and
# busybox wget resolves "localhost" to the IPv6 loopback first, which
# gets a misleading "connection refused" instead of actually probing it.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:2019/config/ || exit 1
