#!/usr/bin/env bash
set -euo pipefail

# rollback.sh — Put production back to how it was before the last deploy:
# the previous images, and the database snapshot taken alongside them.
#
# Why both halves together. Rolling back code alone doesn't work across a
# schema change — sqlx checks on startup that every migration recorded in
# the database is one the binary knows about, so an older image meeting a
# newer database exits with `VersionMissing` and never boots. And rolling
# back the database alone leaves new code running against an old schema.
# The two move as a pair, which is why this is one command.
#
# Where the pieces come from, both written by `scripts/deploy.sh`:
#   - `tile-lite-elite-{server,web}:previous` — retagged from `:latest`
#     immediately before the new images are loaded, so the last known-good
#     build stays on the VM instead of being pruned. Rollback is then a
#     retag, not a rebuild: seconds, no transfer.
#   - `snapshots/pre-<version>-<sha>-<when>.tgz` — the database as it was
#     before that deploy, taken with the server stopped so SQLite's WAL is
#     quiesced.
#
# **Restoring discards everything written since the snapshot** — every
# game, move and account. That is the accepted trade, and it assumes a
# rollback happens promptly, while the lost writes are the few games played
# since the deploy. It is not a way to recover last week; for that, take a
# real backup (docs/3.4's Backups section) and keep it off the VM.
#
# Usage:
#   ./scripts/rollback.sh                    # show what's available, change nothing
#   ./scripts/rollback.sh <snapshot>         # database + images back
#   ./scripts/rollback.sh --db-only <snap>   # database only, leave images alone
#   ./scripts/rollback.sh --yes <snapshot>   # skip the confirmation (deploy.sh
#                                            # uses this when a deploy it just
#                                            # made has already failed)
#
# Configure via the same environment variables as deploy.sh:
#   DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_KEY, DEPLOY_REMOTE_DIR, PROD_URL

# Which environment this is pointed at. Everything defaults to production,
# so an unset environment behaves exactly as this script always has — but
# the wording below follows DEPLOY_ENV, because being told you are about to
# destroy "production" while pointed at a rehearsal host is precisely the
# wrong thing to read when confirming the most destructive command here.
DEPLOY_ENV="${DEPLOY_ENV:-production}"
ENV_LABEL="$DEPLOY_ENV"
DEPLOY_HOST="${DEPLOY_HOST:-129.151.69.246}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"
# The URL of the host this script is acting on — production by default, the
# rehearsal host when a wrapper says so. Named TARGET_URL rather than
# PROD_URL because it is not always production: deploy-preview.sh and
# status.sh both use PROD_URL to mean the *live site*, and one name meaning
# both "my target" and "the live site" in scripts that run in the same
# session is how a value set for one silently changes the other (#24).
# Whether TARGET_URL came from the environment, recorded before defaulting —
# the guard below needs to tell "the caller set it" from "we defaulted it".
TARGET_URL_FROM_ENV="${TARGET_URL:+yes}"
TARGET_URL="${TARGET_URL:-https://tileliteelite.com}"
if [[ -n "${PROD_URL:-}" && -z "$TARGET_URL_FROM_ENV" ]]; then
  echo "error: PROD_URL is set but this script now reads TARGET_URL." >&2
  echo "       It was renamed because PROD_URL means the live site elsewhere;" >&2
  echo "       silently honouring it here would smoke-test the wrong host." >&2
  echo "       Set TARGET_URL=${PROD_URL} instead." >&2
  exit 1
fi

# `-n` redirects ssh's stdin from /dev/null. Without it ssh reads the
# script's own stdin, and a command run before an interactive prompt
# swallows the answer: rollback.sh's confirmation read hit EOF and
# `set -e` aborted it. Found during the 2026-08-01 rollback drill, on the
# most destructive command in the repo — the one place a prompt must work.
SSH_OPTS=(-n -i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"

ASSUME_YES=0
DB_ONLY=0
SNAPSHOT=""
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --db-only) DB_ONLY=1 ;;
    -*) echo "error: unknown option '$arg'" >&2; exit 1 ;;
    *) SNAPSHOT="$arg" ;;
  esac
done

# No snapshot named: show the state and stop. Listing is the safe default
# deliberately — the destructive form has to be asked for by name, and you
# can't name one without having seen this first.
if [[ -z "$SNAPSHOT" ]]; then
  echo "==> ${ENV_LABEL^} ($DEPLOY_HOST)"
  CURRENT="$(curl -sf --max-time 8 "$TARGET_URL/health" 2>/dev/null || true)"
  echo "    live now:  $(printf '%s' "$CURRENT" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || echo unknown)"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "
      cd $DEPLOY_REMOTE_DIR 2>/dev/null || { echo '    (no deploy directory)'; exit 0; }
      if docker image inspect tile-lite-elite-server:previous > /dev/null 2>&1; then
          echo \"    :previous  \$(docker image inspect -f '{{.Created}}' tile-lite-elite-server:previous | cut -c1-19) (image rollback available)\"
      else
          echo '    :previous  none — no image to roll back to (use ./scripts/deploy.sh <ref> instead)'
      fi
      echo
      echo '    Snapshots (newest first):'
      if ! ls snapshots/*.tgz > /dev/null 2>&1; then
          echo '      (none yet — deploy.sh writes one before each deploy)'
          exit 0
      fi
      ls -1t snapshots/*.tgz | while read -r f; do
          printf '      %-50s %6s  %s\n' \"\$(basename \"\$f\")\" \"\$(du -h \"\$f\" | cut -f1)\" \"\$(date -r \"\$f\" -u +%Y-%m-%dT%H:%MZ)\"
      done
  "
  echo
  echo "    Roll back with: ./scripts/rollback.sh <snapshot-name>"
  echo "    A name reads pre-<version>-<commit>: the snapshot taken immediately"
  echo "    *before* <commit> was deployed. Restoring it returns you to whatever"
  echo "    was live before <commit> — not to <commit> itself."
  exit 0
fi

# Check the snapshot exists before saying anything alarming, so a typo
# produces "not found" rather than a scary prompt for an impossible restore.
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "test -f $DEPLOY_REMOTE_DIR/snapshots/$SNAPSHOT"; then
  echo "error: no snapshot named '$SNAPSHOT' on $DEPLOY_HOST." >&2
  echo "       Run without arguments to list what's there." >&2
  exit 1
fi

if (( DB_ONLY == 0 )); then
  if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "docker image inspect tile-lite-elite-server:previous > /dev/null 2>&1"; then
    echo "error: no ':previous' image on the VM, so the code can't be rolled back here." >&2
    echo "       Deploy the older commit explicitly instead:  ./scripts/deploy.sh <ref>" >&2
    echo "       (or pass --db-only if you only meant to restore the database)" >&2
    exit 1
  fi
fi

if (( ASSUME_YES == 0 )); then
  CURRENT="$(curl -sf --max-time 8 "$TARGET_URL/health" 2>/dev/null \
    | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  echo "==> About to roll $ENV_LABEL back on $DEPLOY_HOST"
  echo "        snapshot:  $SNAPSHOT"
  echo "        live now:  ${CURRENT:-unknown}"
  if (( DB_ONLY == 1 )); then
    echo "        images:    unchanged (--db-only)"
  else
    echo "        images:    :previous -> :latest"
  fi
  echo
  echo "    This DISCARDS every game, move and account created since that"
  echo "    snapshot was taken. It cannot be undone."
  echo
  read -r -p "    Type the snapshot name again to confirm: " CONFIRM
  if [[ "$CONFIRM" != "$SNAPSHOT" ]]; then
    echo "    Names don't match — nothing was changed."
    exit 1
  fi
fi

echo "==> Rolling back"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR

    # Stop the server first. Replacing the files under a live SQLite
    # connection would leave it reading a database that no longer exists.
    docker compose stop server > /dev/null

    if [ '$DB_ONLY' = '0' ]; then
        docker image tag tile-lite-elite-server:previous tile-lite-elite-server:latest
        docker image tag tile-lite-elite-web:previous tile-lite-elite-web:latest
    fi

    # Clear the volume before unpacking rather than untarring over the top:
    # the WAL and shm sidecars from the *current* database would otherwise
    # survive and be replayed onto the restored main file, silently
    # reintroducing some of the writes being discarded. \`--entrypoint sh\`
    # because the app image's own entrypoint is the server.
    docker run --rm \
        -v tile-lite-elite-data:/data \
        -v \"\$PWD/snapshots\":/snapshots:ro \
        --entrypoint sh \
        tile-lite-elite-server:latest \
        -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /snapshots/$SNAPSHOT -C /data'

    docker compose up -d
"

echo "==> Waiting for it to come back"
for _ in $(seq 1 30); do
  HEALTH="$(curl -sf --max-time 5 "$TARGET_URL/health" 2>/dev/null || true)"
  if [[ -n "$HEALTH" ]]; then
    echo "    $HEALTH"
    echo "==> Rolled back."
    exit 0
  fi
  sleep 2
done

echo "warning: $ENV_LABEL didn't answer /health within 60s after the rollback." >&2
echo "         Check it: ssh into the VM and 'docker compose logs --tail=50 server'" >&2
exit 1
