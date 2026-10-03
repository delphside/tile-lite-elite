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
#        PAR_URL=... backup-to-oci.sh
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: backup-to-oci.sh
       PAR_URL=... backup-to-oci.sh

Takes a consistent VACUUM INTO copy of production's database and
uploads it to OCI Object Storage via a write-only pre-authenticated
request, so a backup exists somewhere the production host cannot
itself delete.

Refuses (exit 1) when:
  - no PAR_URL is set and ~/.tile-lite-elite-backup-par is unreadable
    -> "error: no PAR_URL, and no ~/.tile-lite-elite-backup-par"
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

COMPOSE="${COMPOSE:-$HOME/tile-lite-elite/docker-compose.yml}"
PAR_URL="${PAR_URL:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# `PAR_URL` is read from a file rather than the environment so the timer unit
# does not carry a credential in `systemctl show` output, which is world
# readable. 0600, owned by the user the timer runs as.
if [[ -z "$PAR_URL" && -r "$HOME/.tile-lite-elite-backup-par" ]]; then
  PAR_URL="$(< "$HOME/.tile-lite-elite-backup-par")"
fi
[[ -n "$PAR_URL" ]] || { echo "error: no PAR_URL, and no ~/.tile-lite-elite-backup-par" >&2; exit 1; }

# --- 1. a consistent copy, with the server still serving ---------------------
#
# Into /data so the file lands on the volume the container can write, then out
# through `docker compose cp`. Writing to a bind mount would need one, and the
# volume already exists.
docker compose -f "$COMPOSE" exec -T server \
  sqlite3 /data/tile-lite-elite.sqlite3 "VACUUM INTO '/data/backup-$STAMP.sqlite3'"
docker compose -f "$COMPOSE" cp "server:/data/backup-$STAMP.sqlite3" "$WORK/db.sqlite3"
docker compose -f "$COMPOSE" exec -T server rm -f "/data/backup-$STAMP.sqlite3"

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
# `--fail` so an HTTP error is an exit status rather than a page of HTML written
# to a file nobody reads. The PAR URL ends in /o/, so the object name is appended.
if ! curl --fail --silent --show-error --max-time 300 \
     -T "$WORK/db.sqlite3.gz" "${PAR_URL}db-$STAMP.sqlite3.gz"; then
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
curl --fail --silent --show-error --max-time 60 \
  -T "$WORK/marker" "${PAR_URL}marker-backup-ok" \
  || echo "warning: backup uploaded but the marker did not; the alarm will fire" >&2
