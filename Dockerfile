# syntax=docker/dockerfile:1

# Single Dockerfile, multiple final targets — `runtime-server` and
# `runtime-web` both build from the same `builder` stage so Docker only
# compiles the workspace once. Select which one to build with `--target`
# (docker-compose.yml does this per service).

# All three base images below are pinned by digest — #360. A floating tag
# meant the image could move without a commit saying so, which is the same
# defect as an unpinned dependency and the reason `TILE_LITE_ELITE_BUILD_ID`
# identifies a build by its artefact digest rather than by the commit that
# named it (#214). Pinning turns a base bump into an ordinary, diffable
# commit instead: bump it here, `.github/dependabot.yml`'s `docker`
# ecosystem watches for the next one, and the build goes through preview and
# rehearsal like any other change. The tag stays alongside the digest so the
# line still reads for a person; the `@sha256:...` is what Docker actually
# resolves.
FROM rust:1-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e AS builder
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

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS runtime-server
# curl is otherwise unused here — pulled in solely so HEALTHCHECK below has
# something to hit /health with, without reaching for a heavier base image.
#
# sqlite3 is here for two jobs the image could not do without it (#174).
#
# **The nightly backup needs a *consistent* copy while the server is running.**
# `VACUUM INTO` gives one; a tar of the volume gives a crash-consistent set that
# depends on the WAL being caught with the file it completes. The alternative
# was `docker compose stop server` every night — which is what `deploy.sh` does,
# and is fine as a deliberate act at a chosen moment, less so unattended at
# 03:00 while somebody is mid-move.
#
# **And it retires a wart `docs/3.4` already complains about**: reading the
# database on production installed the sqlite package into a throwaway Alpine
# container on every single invocation, needing the network each time.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl sqlite3 \
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

FROM caddy:2-alpine@sha256:de23def33b17fb5d1290b0f6c2add1d70780e52341896c00a4c8a2a2fe9d355e AS runtime-web
COPY --from=builder /workspace/target/dx/tile-lite-elite-ui/release/web/public /srv
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 80
# Probes the site's own files, through a loopback-only listener the Caddyfile
# adds for exactly this (`http://127.0.0.1:2020`). It proves routing, the file
# server and the static build — a broken static root fails it.
#
# NOT the public :80/:443 site, and not because nobody tried: a bare loopback
# probe there fails in production, because Caddy's global HTTP->HTTPS redirect
# fires for any Host on :80 and the TLS handshake on :443 then fails with no
# cert for that SNI. Preview has no TLS, so that only showed up once deployed —
# a real lesson in why "verified" means checked against the environment that
# actually differs.
#
# It was Caddy's admin API until 2026-08-21 (#174), which answered "the process
# is alive and a config is loaded" and nothing about whether the site serves —
# and logged every probe, at 2,858 lines a day against 19 real ones.
#
# Must be 127.0.0.1, not localhost: busybox wget resolves "localhost" to the
# IPv6 loopback first, which gets a misleading "connection refused".
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
    CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:2020/version.txt || exit 1
