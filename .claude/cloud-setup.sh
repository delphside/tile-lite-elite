#!/usr/bin/env bash
# cloud-setup.sh — SessionStart: make a Claude Code cloud session able to build,
# lint and test this repository, including the Playwright suite.
#
# **Cloud only.** It exits at once unless CLAUDE_CODE_REMOTE is `true`, which
# a cloud session's VM sets and a local one never does, so on the WSL machine
# and in VS Code it does nothing. A local machine is set up once by
# scripts/develop/setup-dev-environment.sh (docs/4.3.1).
#
# **Run every session, not cached.** The environment's own setup script is
# snapshotted and reused; a SessionStart hook is not, so this pays its cost on
# each start and resume. It is kept to what is fast: prebuilt binaries from
# GitHub releases rather than `cargo install`, which compiled dx from source
# for most of a 108-minute session on 2026-10-03. Each step checks first, so a
# resumed session whose VM kept its files skips it.
#
# What it provides:
#   - the toolchain rust-toolchain.toml pins, with its wasm32 target
#   - dx and wasm-bindgen at the versions Cargo.lock pins (the same rule as
#     setup-dev-environment.sh: a mismatch builds a client that does not run)
#   - bats and its helpers, for scripts/tests (CI installs them the same way),
#     and sqlite3, which the e2e teardown's account cleanup uses
#   - e2e/node_modules
#   - the repository's git hooks, switched on as a local clone has them
#   - the `programme/` submodule (the pinned generic documents and tooling,
#     #485). Not the live programme checkout: a cloud session has that already,
#     cloned beside this repository, which is where the scripts look for it
#   - for the session: RUSTC_WRAPPER emptied, because .cargo/config.toml names
#     one machine's sccache; and the preinstalled Chromium for Playwright,
#     because the cloud network refuses Playwright's own browser download
#
# Not here: dioxus-desktop's system libraries. Desktop builds are rare and the
# libraries add ~25s to every start, so they belong in the environment's
# cached setup script — docs/4.3.1 has the line.
#
# Never fails a session: a step that cannot finish says so and the rest go on.
# Progress goes to stderr; stdout is one line for Claude's context, plus one
# more when the live programme checkout needs attention (board-records.py check).

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}" || exit 0
BIN="$HOME/.cargo/bin"
mkdir -p "$BIN"
missing=()

# The version of a package as Cargo.lock pins it.
locked_version() {
  grep -A1 "^name = \"$1\"$" Cargo.lock | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1
}

# Extract a release tarball's named binaries into $BIN.
fetch_release() {  # url strip-components binary...
  local url=$1 strip=$2
  shift 2
  curl -fsSL --retry 3 "$url" | tar xz -C "$BIN" --strip-components="$strip" --wildcards "${@/#/*}"
}

# --- Rust toolchain and wasm target ------------------------------------------
# rustup reads rust-toolchain.toml and installs channel, components and target.
rustup toolchain install >&2 2>&1 || missing+=("rust toolchain")

# --- dx ----------------------------------------------------------------------
DX_VERSION=$(locked_version dioxus)
if [[ -z "$DX_VERSION" ]]; then
  missing+=("dx (no dioxus version in Cargo.lock)")
elif [[ "$("$BIN/dx" --version 2>/dev/null)" != *"$DX_VERSION"* ]]; then
  echo "cloud-setup: dx $DX_VERSION" >&2
  fetch_release "https://github.com/DioxusLabs/dioxus/releases/download/v$DX_VERSION/dx-x86_64-unknown-linux-gnu-v$DX_VERSION.tar.gz" 0 dx \
    || missing+=("dx $DX_VERSION")
fi

# --- wasm-bindgen ------------------------------------------------------------
WB_VERSION=$(locked_version wasm-bindgen)
if [[ -z "$WB_VERSION" ]]; then
  missing+=("wasm-bindgen (no version in Cargo.lock)")
elif [[ "$("$BIN/wasm-bindgen" --version 2>/dev/null)" != *"$WB_VERSION"* ]]; then
  echo "cloud-setup: wasm-bindgen $WB_VERSION" >&2
  fetch_release "https://github.com/rustwasm/wasm-bindgen/releases/download/$WB_VERSION/wasm-bindgen-$WB_VERSION-x86_64-unknown-linux-musl.tar.gz" 1 \
      wasm-bindgen wasm-bindgen-test-runner wasm2es6js \
    || missing+=("wasm-bindgen $WB_VERSION")
fi

# --- bats, sqlite3 for the e2e teardown's cleanup, and caddy for the Caddyfile gate test ---
if ! dpkg -s bats bats-support bats-assert sqlite3 caddy >/dev/null 2>&1; then
  echo "cloud-setup: bats, sqlite3, caddy" >&2
  { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bats bats-support bats-assert sqlite3 caddy; } >&2 2>&1 \
    || missing+=("bats/sqlite3/caddy")
fi

# --- e2e dependencies --------------------------------------------------------
# `npm install` rather than `npm ci`: ci deletes node_modules first, so a
# resumed session would reinstall what it already has.
(cd e2e && npm install --no-audit --no-fund --loglevel=error) >&2 2>&1 || missing+=("e2e node_modules")

# --- the programme submodule ---------------------------------------------------
# The skills and agents in .claude/ link into it, the git hooks and the Claude
# hooks are in it, and the scripts read the generic documents from it. The live
# checkout of the programme's records is not this: the cloud session has it
# beside the repository already.
git submodule update --init >&2 2>&1 || missing+=("programme submodule")

# --- git hooks ---------------------------------------------------------------
# The same switch setup-dev-environment.sh makes locally: `.githooks`, this
# repository's shim in front of the programme's hooks in the submodule above
# (#485). The shim exists whether or not the submodule does, so a failed update
# is refused at the first commit with the way out, not run as no hook. Each
# hook runs with what this VM has: pre-commit's checks need only cargo, python3 and
# npx, and post-merge acts only on a merge into main, which a cloud session never
# makes. The shim also sets the submodule's own hooks path, which refuses a commit
# made inside the pinned copy (the programme's 485 design, T1); done here as well
# so it holds before the first hook runs.
git config core.hooksPath .githooks || missing+=("git hooks")
[[ -d programme/.githooks/in-submodule ]] && git -C programme config core.hooksPath .githooks/in-submodule

# --- the live programme checkout ----------------------------------------------
# board-records.py says in one line if it is missing, off main or behind the
# local origin/main, and nothing when it is fine. It changes nothing.
PROGRAMME_NOTE=$(programme/scripts/board/board-records.py check 2>/dev/null || true)

# --- session environment -----------------------------------------------------
CHROMIUM=$(ls -d /opt/pw-browsers/chromium-*/chrome-linux/chrome 2>/dev/null | sort -V | tail -1)
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  {
    echo 'export RUSTC_WRAPPER=""'
    [[ -n "$CHROMIUM" ]] && echo "export PLAYWRIGHT_CHROMIUM_EXECUTABLE=\"$CHROMIUM\""
  } >>"$CLAUDE_ENV_FILE"
fi
[[ -n "$CHROMIUM" ]] || missing+=("preinstalled Chromium")

if ((${#missing[@]})); then
  printf 'cloud-setup: ready except: %s. See .claude/cloud-setup.sh.\n' "$(IFS=,; echo "${missing[*]}")"
else
  echo "cloud-setup: dx $DX_VERSION, wasm-bindgen $WB_VERSION, the pinned toolchain, bats, sqlite3 and e2e dependencies are installed, and the git hooks (.githooks, the shim in front of the programme's) are on. Playwright uses the preinstalled Chromium (PLAYWRIGHT_CHROMIUM_EXECUTABLE); start dev with ./scripts/develop/services.sh start."
fi
[[ -n "$PROGRAMME_NOTE" ]] && echo "$PROGRAMME_NOTE"
exit 0
