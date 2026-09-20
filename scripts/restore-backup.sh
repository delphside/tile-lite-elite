#!/usr/bin/env bash
# Restore a database from the offsite backups (#174).
#
# **This does not run on the production VM, and cannot.** The VM holds a
# write-only pre-authenticated request: it can upload and cannot read, list or
# delete. That is the point — an attacker on the box cannot reach the backups —
# and the cost is that restoring happens from somewhere else, with a credential
# created for the occasion.
#
# **Make a read PAR in the console when you need one, and delete it after.**
# Bucket → Management → Pre-Authenticated Requests → Create: target *bucket*,
# access *permit object reads*, **object listing on**, expiry a day or two. No
# standing read credential exists anywhere, which is what makes a leaked one a
# short-lived problem rather than a permanent one.
#
# Usage:
#   restore-backup.sh <read-par-url>                 newest backup, into a file
#   restore-backup.sh <read-par-url> --into <volume> and load it into a volume
#   restore-backup.sh <read-par-url> --object <name> a specific one
#
# **Run it on a schedule, not only in an emergency.** A backup nobody has
# restored is a hypothesis, and the alarm on the restore marker exists to make
# that happen about every hundred days.
set -euo pipefail

PAR=""; INTO=""; OBJECT=""; MARK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --into)   INTO="$2"; shift 2 ;;
    --object) OBJECT="$2"; shift 2 ;;
    --mark)   MARK="$2"; shift 2 ;;   # a write PAR, to refresh the restore marker
    -h|--help)
      cat <<'EOF'
usage: restore-backup.sh <read-par-url>                 newest backup, into a file
       restore-backup.sh <read-par-url> --into <volume> and load it into a volume
       restore-backup.sh <read-par-url> --object <name> a specific one
       restore-backup.sh <read-par-url> --mark <write-par-url>  also refresh
                                          the 100-day restore-drill marker

Restores from the offsite backups (#174). Never run on the production
VM itself — its PAR is write-only and cannot read, list or delete; see
the header comment above. Make a short-lived read PAR in the console
for this, and delete it after.

Refuses (exit 1) when:
  - no PAR URL is given
    -> "error: give me a read pre-authenticated request URL (see --help)"
  - the PAR URL doesn't end in /o/ (the bucket-listing form)
    -> "error: the PAR URL should end in /o/ — that is the bucket form"
  - no db-*.sqlite3.gz object exists in the bucket
    -> "error: no db-*.sqlite3.gz objects in that bucket"
  - the downloaded file fails PRAGMA integrity_check
    -> "error: the downloaded backup fails its integrity check: ..."
  - the backup is a valid database with zero players in it
    -> "error: the backup is a valid database with no players in it"
EOF
      exit 0
      ;;
    *)        PAR="$1"; shift ;;
  esac
done
[[ -n "$PAR" ]] || { echo "error: give me a read pre-authenticated request URL (see --help)" >&2; exit 1; }
[[ "$PAR" == */o/ ]] || { echo "error: the PAR URL should end in /o/ — that is the bucket form" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- pick the object ----------------------------------------------------------
if [[ -z "$OBJECT" ]]; then
  # Listing returns JSON; the names sort lexically because the timestamp in them
  # is ISO-8601 UTC, which is the whole reason for naming them that way.
  curl --fail --silent --show-error --max-time 60 "$PAR" > "$WORK/list.json"
  OBJECT="$(python3 -c '
import json,sys
names = [o["name"] for o in json.load(open(sys.argv[1]))["objects"]
         if o["name"].startswith("db-")]
print(sorted(names)[-1] if names else "")' "$WORK/list.json")"
  [[ -n "$OBJECT" ]] || { echo "error: no db-*.sqlite3.gz objects in that bucket" >&2; exit 1; }
  echo "newest backup: $OBJECT"
fi

# --- fetch and verify ---------------------------------------------------------
curl --fail --silent --show-error --max-time 300 "${PAR}${OBJECT}" > "$WORK/db.gz"
gunzip -c "$WORK/db.gz" > "$WORK/db.sqlite3"

RESULT="$(sqlite3 "$WORK/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 || true)"
[[ "$RESULT" == "ok" ]] || { echo "error: the downloaded backup fails its integrity check: $RESULT" >&2; exit 1; }

PLAYERS="$(sqlite3 "$WORK/db.sqlite3" 'select count(*) from players;' 2>/dev/null || echo '?')"
GAMES="$(sqlite3 "$WORK/db.sqlite3" 'select count(*) from games;' 2>/dev/null || echo '?')"
echo "verified: integrity ok, $PLAYERS players, $GAMES games"

# Counting rows is not decoration. `integrity_check` says the file is a
# well-formed database; it says nothing about whether it is *our* database with
# anything in it. An empty but valid file would pass the first check and fail
# the only test that matters.
[[ "$PLAYERS" != "0" ]] || { echo "error: the backup is a valid database with no players in it" >&2; exit 1; }

# --- load it, if asked --------------------------------------------------------
if [[ -n "$INTO" ]]; then
  echo "loading into volume $INTO — anything already there is replaced"
  docker run --rm -v "$INTO:/data" -v "$WORK:/in:ro" debian:bookworm-slim \
    sh -c 'rm -f /data/tile-lite-elite.sqlite3 /data/*-wal /data/*-shm \
           && cp /in/db.sqlite3 /data/tile-lite-elite.sqlite3'
  echo "loaded. Start the stack and check the site serves."
else
  cp "$WORK/db.sqlite3" "./restored-$OBJECT.sqlite3" 2>/dev/null \
    || cp "$WORK/db.sqlite3" "./restored.sqlite3"
  echo "written to ./restored-*.sqlite3 — not loaded anywhere"
fi

# --- say the drill happened ---------------------------------------------------
if [[ -n "$MARK" ]]; then
  # From a file, not stdin: OCI rejects chunked uploads with 501. See the note
  # in backup-to-oci.sh.
  printf '%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" > "$WORK/marker"
  curl --fail --silent --show-error \
    --max-time 60 -T "$WORK/marker" "${MARK}marker-restore-ok" \
    && echo "restore marker refreshed — the 100-day alarm is reset"
fi
