#!/usr/bin/env bash
# Take a consistent copy of the production database and put it somewhere the
# production machine cannot reach (#174).
#
# **Why offsite at all.** `deploy.sh` already snapshots before every deploy and
# keeps five — a good procedure that protects against a bad deploy, and useless
# against losing the box, because the snapshots are on the box. Two gaps: nothing
# leaves the VM, and nothing happens without a deploy, so a quiet fortnight means
# the newest copy is a fortnight old.
#
# **Why the VM cannot destroy what it writes.** The credential is a bucket-scoped
# pre-authenticated request with *permit object writes* and listing off. Tested
# from this machine on 2026-08-21: PUT 200, and GET, LIST, DELETE and HEAD all
# 404. So an attacker here — or a bug in this script — cannot remove a backup.
# The one thing a write PAR *can* do is overwrite an existing name, which is why
# the bucket has object versioning on and why the name carries a timestamp.
#
# **Why `VACUUM INTO` rather than tar.** SQLite runs in WAL mode, so copying the
# database file while the server holds it can catch the main file without the WAL
# entry that completes it. `VACUUM INTO` writes a single consistent file with the
# server still running — no downtime, and nothing to reassemble on restore.
#
# Usage: backup-to-oci.sh          (run by tile-lite-elite-backup.timer)
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: backup-to-oci.sh

Takes a consistent VACUUM INTO copy of the environment's database and
sends it through upload.sh, beside this script. TLE_UPLOAD in the one
/var/lib/turpin/tile-lite-elite/*/.env chooses where it goes: `par`
(OCI Object Storage via a write-only pre-authenticated request, from
PAR_URL or ~/.tile-lite-elite-backup-par), `local` (uploads/ in that
state folder) or `local-fail` (tests). It holds that folder's `lock`
for the run, waiting up to TLE_LOCK_WAIT seconds (default 1800), and
finds the server by its Compose labels.

Refuses (exit 1) when:
  - there is not exactly one /var/lib/turpin/tile-lite-elite/*/.env
    (TLE_TURPIN_ROOT overrides the root)
  - TLE_UPLOAD is not par, local or local-fail
  - TLE_UPLOAD is par, no PAR_URL is set and
    ~/.tile-lite-elite-backup-par is unreadable
    -> "error: no PAR_URL, and no ~/.tile-lite-elite-backup-par"
  - the lock is not free within the wait
  - there is not exactly one running server container
  - the fresh copy fails PRAGMA integrity_check
    -> "error: integrity check failed on the fresh copy: ..."
  - the upload itself fails (the previous backup is left untouched)
    -> "error: upload failed; the previous backup is untouched"

Only warns (exit 0) when the backup uploaded but the success marker
did not — the alarm then fires on that absence:
  -> "warning: backup uploaded but the marker did not; the alarm will fire"
EOF
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=upload.sh
. "$HERE/upload.sh"

tle_upload_init || exit 1

# A deploy holds the same lock, so a backup never reads a database mid-change.
# Run again under it, waiting longer than a deploy takes.
if [[ -z "${TLE_LOCKED:-}" ]]; then
  exec env TLE_LOCKED=1 flock -w "${TLE_LOCK_WAIT:-1800}" "$STATE_DIR/lock" bash "$0" "$@"
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The server by its Compose labels. Not `turpin-host compose`, which refuses
# while the deploy lock is held, and this script holds it.
mapfile -t SERVERS < <(docker ps -q \
  --filter label=com.docker.compose.project=tile-lite-elite \
  --filter label=com.docker.compose.service=server \
  --filter status=running)
if [[ ${#SERVERS[@]} -ne 1 ]]; then
  echo "error: expected one running tile-lite-elite server container, found ${#SERVERS[@]}" >&2
  exit 1
fi
SERVER="${SERVERS[0]}"

# --- 1. a consistent copy, with the server still serving ---------------------
#
# Into /data so the file lands on the volume the container can write, then out
# through `docker cp`.
docker exec "$SERVER" \
  sqlite3 /data/tile-lite-elite.sqlite3 "VACUUM INTO '/data/backup-$STAMP.sqlite3'"
docker cp "$SERVER:/data/backup-$STAMP.sqlite3" "$WORK/db.sqlite3"
docker exec "$SERVER" rm -f "/data/backup-$STAMP.sqlite3"

# --- 2. verify it before trusting it ------------------------------------------
#
# A backup nobody has opened is a hypothesis. `integrity_check` on the copy costs
# a second at this size and turns "the file transferred" into "the file is a
# database", which are different claims.
RESULT="$(sqlite3 "$WORK/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 || true)"
if [[ "$RESULT" != "ok" ]]; then
  echo "error: integrity check failed on the fresh copy: $RESULT" >&2
  exit 1
fi

gzip -9 "$WORK/db.sqlite3"
SIZE="$(stat -c%s "$WORK/db.sqlite3.gz")"

# --- 3. upload -----------------------------------------------------------------
#
if ! tle_upload "$WORK/db.sqlite3.gz" "db-$STAMP.sqlite3.gz" 300; then
  echo "error: upload failed; the previous backup is untouched" >&2
  exit 1
fi

echo "uploaded db-$STAMP.sqlite3.gz ($SIZE bytes)"

# --- 4. say that it worked ------------------------------------------------------
#
# A marker object refreshed only on success, so the alarm watches for **absence
# of success** rather than for a failure message. That also catches this script
# crashing, the timer never being enabled, the host being down, or the credential
# expiring — none of which would ever send a failure.
#
# **Uploaded from a file, never from stdin.** `curl -T -` cannot know the length
# in advance, so it sends `Transfer-Encoding: chunked` — which OCI Object
# Storage rejects with **501 Not Implemented**. Measured on the production host,
# 2026-08-23: stdin 501, the identical bytes from a file 200. All three markers
# in this project had the same bug, so none of the three alarms could ever have
# been satisfied.
printf '%s\n' "$STAMP" > "$WORK/marker"
tle_upload "$WORK/marker" marker-backup-ok 60 \
  || echo "warning: backup uploaded but the marker did not; the alarm will fire" >&2
