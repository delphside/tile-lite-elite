#!/usr/bin/env bash
set -euo pipefail

# seed-rehearsal.sh — copy production's database into the rehearsal host, so
# a migration is rehearsed against real rows rather than an empty volume.
#
# Why it matters: a migration that applies cleanly to nothing proves very
# little. The schema incidents in docs/4.4.2 are all about applying to data
# that already exists — wrong types, unexpected nulls, a UNIQUE that only
# collides once there are duplicates to collide.
#
# It uses the snapshots deploy.sh already writes before every production
# deploy, rather than exporting separately. Nothing new runs against
# production: this reads a file that is already there.
#
# **Routed through this machine deliberately.** The two hosts share a subnet
# and could copy directly, but that needs one to hold the other's SSH key,
# which throws away the isolation the separate rehearsal key exists for. The
# database is a few megabytes; the private network saves nothing worth that.
#
# **The copy contains real accounts** — email addresses and password hashes.
# The rehearsal host is configured like production for that reason: its own
# key, the same firewall rules, TLS. Treat a seeded rehearsal host as
# carrying production data, because it does.
#
#   ./scripts/deliver/seed-rehearsal.sh          # newest production snapshot
#   ./scripts/deliver/seed-rehearsal.sh <name>   # a specific one

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: seed-rehearsal.sh [snapshot-name]

Copies one of production's own deploy.sh snapshots into the rehearsal
host, discarding whatever rehearsal's database held. With no argument,
uses the newest snapshot on production; production is only ever read
from, never written to.

Refuses (exit 1) when:
  - no snapshot name is given and production has none yet
    -> "error: no snapshot found on production ($PROD_HOST)."
  - `turpin-host compose` refuses on the rehearsal host (no current deploy,
    lock held), or ssh fails, before the restore completes
    -> "seed-rehearsal: the restore did not complete ..."
  - the rehearsal host does not answer /health within 60s of the
    restore (its own database may be mid-restart; check with
    'turpin-host compose tile-lite-elite rehearsal logs --tail=50 server' over ssh)
    -> "warning: no /health within 60s. ..."

The copy carries real accounts (email addresses, password hashes), so
treat a seeded rehearsal host as carrying production data — see the
comment above on why it is configured like production for that reason.
EOF
  exit 0
fi

# Rehearsal's address, key and compose command, which rehearsal-target.sh names once.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/deliver/rehearsal-target.sh
. "$HERE/rehearsal-target.sh"

PROD_HOST="${PROD_DEPLOY_HOST:-129.151.69.246}"
PROD_KEY="${PROD_DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
REHEARSAL_HOST="${DEPLOY_HOST:-129.151.84.183}"
# The ssh *key path*. Not `REHEARSAL_ACCESS_KEY`, which is the access gate's
# shared secret in docker-compose.yml (#240) — different thing, deliberately
# different name.
REHEARSAL_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite_rehearsal}"
REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"
REHEARSAL_URL="${REHEARSAL_URL:-https://129.151.84.183.sslip.io}"

PROD_SSH=(-n -i "$PROD_KEY" -o ConnectTimeout=10)
REH_SSH=(-n -i "$REHEARSAL_KEY" -o ConnectTimeout=10)
REH_SCP=(-i "$REHEARSAL_KEY" -o ConnectTimeout=10)

SNAPSHOT="${1:-}"
if [[ -z "$SNAPSHOT" ]]; then
  # `|| true` — grep/ls finding nothing must not kill the assignment under
  # `set -o pipefail`; the empty check below is what reports it.
  SNAPSHOT="$(ssh "${PROD_SSH[@]}" "ubuntu@$PROD_HOST" \
    "ls -1t $REMOTE_DIR/snapshots/*.tgz 2>/dev/null | head -1 | xargs -r basename" || true)"
fi
if [[ -z "$SNAPSHOT" ]]; then
  echo "error: no snapshot found on production ($PROD_HOST)." >&2
  echo "       deploy.sh writes one before each deploy; there may not have been one yet." >&2
  exit 1
fi

echo "==> Seeding rehearsal from production's $SNAPSHOT"
echo "    This DISCARDS the rehearsal database. Production is only read from."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

scp -i "$PROD_KEY" -o ConnectTimeout=10 \
  "ubuntu@$PROD_HOST:$REMOTE_DIR/snapshots/$SNAPSHOT" "$TMP/$SNAPSHOT"
echo "    pulled $(du -h "$TMP/$SNAPSHOT" | cut -f1)"

ssh "${REH_SSH[@]}" "ubuntu@$REHEARSAL_HOST" "mkdir -p $REMOTE_DIR/snapshots"
scp "${REH_SCP[@]}" "$TMP/$SNAPSHOT" "ubuntu@$REHEARSAL_HOST:$REMOTE_DIR/snapshots/seeded-$SNAPSHOT"

# Same restore shape as rollback.sh, and for the same reason: clear the
# volume before unpacking rather than untarring over the top, or the WAL and
# shm sidecars of the *current* database survive and replay onto the
# restored file.
# The stop, the restore and the start all go through `turpin-host compose`,
# which runs Compose against the current deploy under the environment's lock,
# so the restore runs in the current deploy's own server image (not a
# `:latest` that may be another build's) and the old folder's compose file
# never starts the old images. It refuses where rehearsal has no current
# deploy or the lock is held, and then this stops.
ssh "${REH_SSH[@]}" "ubuntu@$REHEARSAL_HOST" "
    set -e
    cd $REMOTE_DIR
    $REHEARSAL_COMPOSE stop server > /dev/null
    $REHEARSAL_COMPOSE run --rm --no-deps \
        -v \"\$PWD/snapshots\":/snapshots:ro \
        --entrypoint sh \
        server \
        -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /snapshots/seeded-$SNAPSHOT -C /data'
    $REHEARSAL_COMPOSE up -d
" || { echo "seed-rehearsal: the restore did not complete (turpin-host compose refused, or ssh failed): rehearsal may be stopped." >&2; exit 1; }

echo "==> Waiting for the rehearsal host to come back"
for _ in $(seq 1 30); do
  HEALTH="$(curl -sf --max-time 5 "$REHEARSAL_URL/health" 2>/dev/null || true)"
  if [[ -n "$HEALTH" ]]; then
    echo "    $HEALTH"
    echo "==> Seeded. The schema_version above is production's, not an empty volume's."
    exit 0
  fi
  sleep 2
done
echo "warning: no /health within 60s. Check: ssh in and 'turpin-host compose tile-lite-elite rehearsal logs --tail=50 server'" >&2
exit 1
