#!/usr/bin/env bash
set -euo pipefail

# deploy-preview.sh — Build and run the preview stack locally (e.g. inside
# WSL), using the exact same Dockerfile/build process as scripts/deploy.sh,
# just without the ssh/scp hop to the real VM. See docs/3.3-testing-ci-and-release.md's
# "Preview Environment" section for why this exists and how to use it.
#
# Every mode builds a *fresh checkout of a commit* in a throwaway
# `git worktree`, never the working tree — same principle as deploy.sh, and
# the reason "preview is running X" is something `at prod`/`verify` can
# trust rather than a coincidence of what was on disk at build time.
# Uncommitted changes are therefore not tested here: commit first (a WIP
# commit is fine, nothing here gets pushed).
#
# Usage:
#   ./scripts/deploy-preview.sh              # build + (re)start the preview
#                                             # stack from the current HEAD
#   ./scripts/deploy-preview.sh down         # stop the preview stack, keep its data
#   ./scripts/deploy-preview.sh reset        # stop the preview stack and wipe its data
#   ./scripts/deploy-preview.sh at <git-ref> # wipe preview, then build + start
#                                             # from a specific commit/tag/branch —
#                                             # runs only the migrations that
#                                             # existed in the repo at that ref
#   ./scripts/deploy-preview.sh at prod      # same, but at whatever commit
#                                             # production is currently running
#                                             # (reads its /health endpoint)
#   ./scripts/deploy-preview.sh verify       # compare preview's live app_version
#                                             # against production's, without
#                                             # changing anything — run this
#                                             # before testing a new deployment,
#                                             # to confirm the starting point
#                                             # actually matches prod
#
# The preview data volume (tile-lite-elite-preview-data) persists across
# ordinary runs, same as production's — running this repeatedly against an
# already-seeded preview DB is what actually exercises "does a new
# migration apply to an existing database", not just a brand-new one.
#
# To test against a realistic copy of production data rather than whatever
# preview has accumulated on its own, restore a production backup
# (docs/3.4-production-environment.md's Backups section) into
# tile-lite-elite-preview-data before running this.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

COMPOSE=(docker compose -f docker-compose.preview.yml)
PROD_URL="${PROD_URL:-https://tileliteelite.com}"
STAGING_URL="http://localhost:8081"

# `/health`'s body is a small, fixed-shape JSON object (api::HealthDto) —
# grep/cut is enough to pull one field out of it without adding a jq
# dependency this script would otherwise have no use for.
fetch_app_version() {
  local url="$1" json version
  if ! json="$(curl -sf --max-time 5 "$url/health")"; then
    echo "error: couldn't reach $url/health" >&2
    return 1
  fi
  # `|| true` so a response without the field reaches the check below
  # rather than killing the script via pipefail — see deploy.sh's note.
  version="$(printf '%s' "$json" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  if [[ -z "$version" ]]; then
    echo "error: $url/health responded but had no app_version field — is it running code from before that field existed?" >&2
    return 1
  fi
  printf '%s\n' "$version"
}

MODE="${1:-up}"

case "$MODE" in
  down)
    "${COMPOSE[@]}" down
    exit 0
    ;;
  reset)
    "${COMPOSE[@]}" down -v
    exit 0
    ;;
  up)
    ;;
  at)
    REF="${2:-}"
    if [[ -z "$REF" ]]; then
      echo "Usage: $0 at <git-ref>|prod" >&2
      exit 1
    fi
    if [[ "$REF" == "prod" ]]; then
      echo "==> Checking production's live version ($PROD_URL/health)"
      PROD_VERSION="$(fetch_app_version "$PROD_URL")" || exit 1
      REF="${PROD_VERSION#*+}"
      if [[ "$REF" == "$PROD_VERSION" ]]; then
        echo "error: production's app_version ($PROD_VERSION) has no build id, so its exact commit isn't known — was it deployed via scripts/deploy.sh, which sets one automatically?" >&2
        exit 1
      fi
      echo "    Production is running $PROD_VERSION -> commit $REF"
    fi
    ;;
  verify)
    ;;
  *)
    echo "Usage: $0 [up|down|reset|at <git-ref>|at prod|verify]" >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "verify" ]]; then
  echo "==> Checking production ($PROD_URL/health)"
  PROD_VERSION="$(fetch_app_version "$PROD_URL")" || exit 1
  echo "    production: $PROD_VERSION"
  echo "==> Checking preview ($STAGING_URL/health)"
  STAGING_VERSION="$(fetch_app_version "$STAGING_URL")" || exit 1
  echo "    preview:    $STAGING_VERSION"
  if [[ "$PROD_VERSION" == "$STAGING_VERSION" ]]; then
    echo "==> Match — preview is running the same version as production"
    exit 0
  else
    echo "==> Mismatch — preview is NOT running the same version as production" >&2
    echo "    Run './scripts/deploy-preview.sh at prod' to bring it in sync." >&2
    exit 1
  fi
fi

# Both remaining modes — plain `up` and `at <ref>` — build the same way: a
# fresh checkout of a commit, never the working tree. They differ only in
# which commit (HEAD vs the given ref) and in whether the preview database
# is wiped first.
#
# `up` used to build the working tree via `compose build`, which made
# "preview is running X" true only by coincidence — whatever happened to be
# on disk when the build ran. Refusing to run on a dirty tree patched over
# that, at the cost of forcing a WIP commit before every preview test.
# Building the commit directly makes the claim true by construction, so the
# dirty tree stops mattering either way.
if [[ "$MODE" == "up" ]]; then
  REF="HEAD"
fi

# Fail fast with a clear message rather than a confusing worktree error
# if the ref doesn't exist locally.
if ! COMMIT="$(git rev-parse --verify "${REF}^{commit}" 2>/dev/null)"; then
  echo "error: '$REF' is not a valid local git ref (fetch it first if it's remote-only)" >&2
  exit 1
fi
SHORT_SHA="$(git rev-parse --short "$COMMIT")"

# Refuses to build an image the preview volume has already moved past — the
# same rule `deploy.sh` applies to production, which preview lacked.
#
# `up` keeps the volume deliberately, so after moving around with
# `at <ref>` (or rehearsing a rollback) the database can be *ahead* of the
# code being built. sqlx then sees an applied migration the binary doesn't
# have, exits with `VersionMissing`, and the container crash-loops. That
# happened for real on 2026-08-01: the volume still carried a migration from
# an abandoned branch, and the only clue was a line buried in
# `docker compose logs`.
#
# Only in `up` mode: `at` wipes the volume first, so there is nothing to
# outrun. Read from the *running* stack, which `up` has not stopped yet.
if [[ "$MODE" == "up" ]]; then
  STAGING_SCHEMA="$(curl -sf --max-time 5 "$STAGING_URL/health" 2>/dev/null \
    | grep -o '"schema_version":[0-9]*' | cut -d: -f2 || true)"
  TARGET_SCHEMA="$(git ls-tree --name-only "$COMMIT" crates/server-game/migrations/ \
    | grep '\.sql$' | sed 's#.*/##' | grep -oE '^[0-9]+' | sort -n | tail -1 | sed 's/^0*//' || true)"
  if [[ -n "$STAGING_SCHEMA" && -n "$TARGET_SCHEMA" ]] && (( STAGING_SCHEMA > TARGET_SCHEMA )); then
    echo "error: preview's database is at migration $STAGING_SCHEMA, but $SHORT_SHA only knows up to $TARGET_SCHEMA." >&2
    echo "       That build would fail sqlx's startup check and crash-loop." >&2
    echo "" >&2
    echo "       The volume is ahead of the code — usually after an 'at <ref>' or a" >&2
    echo "       rollback rehearsal. Wipe it and start clean:" >&2
    echo "         ./scripts/deploy-preview.sh reset && ./scripts/deploy-preview.sh" >&2
    echo "       or build that ref against a fresh volume:" >&2
    echo "         ./scripts/deploy-preview.sh at $SHORT_SHA" >&2
    exit 1
  fi
fi

if [[ "$MODE" == "up" && -n "$(git status --porcelain)" ]]; then
  echo "==> Note: your working tree has uncommitted changes. They are NOT part of this"
  echo "    build — preview runs a clean checkout of HEAD ($SHORT_SHA). Commit to test them."
fi

if [[ "$MODE" == "at" ]]; then
  echo "==> Wiping preview (about to redeploy at $REF ($SHORT_SHA) from scratch)"
  "${COMPOSE[@]}" down -v
fi

# A throwaway `git worktree` rather than checking the commit out in this
# working copy — leaves the actual repo (branch, staged/uncommitted
# changes) completely untouched. `docker build`'s context is a plain
# directory, so this doesn't need docker-compose.preview.yml to have
# existed at that ref, only the Dockerfile and source under crates/.
WORKTREE_DIR="$(mktemp -d /tmp/tile-lite-elite-preview-worktree-XXXXXX)"
cleanup() {
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT
# rmdir first: `git worktree add` refuses to target a directory mktemp
# already created, even an empty one.
rmdir "$WORKTREE_DIR"
git worktree add --detach "$WORKTREE_DIR" "$COMMIT" >/dev/null

# Build metadata baked into both binaries, and what `at prod`/`verify` read
# back out of /health later — see docs/4.1-configuration.md's "Versioning"
# section.
echo "==> Building preview images from $REF ($SHORT_SHA)"
docker build --target runtime-server \
  --build-arg TILE_LITE_ELITE_BUILD_ID="$SHORT_SHA" \
  -t tile-lite-elite-preview-server:latest "$WORKTREE_DIR"
docker build --target runtime-web \
  --build-arg TILE_LITE_ELITE_BUILD_ID="$SHORT_SHA" \
  -t tile-lite-elite-preview-web:latest "$WORKTREE_DIR"

echo "==> Starting preview stack"
"${COMPOSE[@]}" up -d --no-build

# Waits for it to actually answer before claiming success. Without this the
# script printed "Preview is up" and exited 0 while the server was
# crash-looping behind a healthy Caddy — the failure looked like a success
# until someone curled it. Checks the *version* too, so a container that
# never restarted can't pass.
echo "==> Waiting for preview to answer on $SHORT_SHA"
STAGING_READY=0
for _ in $(seq 1 30); do
  LIVE="$(curl -sf --max-time 5 "$STAGING_URL/health" 2>/dev/null \
    | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  if [[ "${LIVE##*+}" == "$SHORT_SHA" ]]; then
    STAGING_READY=1
    echo "    $LIVE"
    break
  fi
  sleep 2
done
if (( STAGING_READY == 0 )); then
  echo "error: preview did not come up on $SHORT_SHA within 60s." >&2
  echo "       Check why:  docker compose -f docker-compose.preview.yml logs --tail=30 server" >&2
  exit 1
fi

if [[ "$MODE" == "at" ]]; then
  echo "==> Preview is up at http://localhost:8081, running $REF ($SHORT_SHA) against a fresh database"
  echo "    Back to the current HEAD: ./scripts/deploy-preview.sh"
  echo "    Verify it matches production:     ./scripts/deploy-preview.sh verify"
else
  echo "==> Preview is up at http://localhost:8081, running HEAD ($SHORT_SHA)"
  echo "    Logs:    docker compose -f docker-compose.preview.yml logs -f server"
  echo "    Down:    ./scripts/deploy-preview.sh down     (keeps data)"
  echo "    Reset:   ./scripts/deploy-preview.sh reset    (wipes preview DB)"
  echo "    Deploy a specific version: ./scripts/deploy-preview.sh at <git-ref>|prod"
fi
