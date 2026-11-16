#!/usr/bin/env bash
# Report a scheduler job that panicked or stalled (#608, #224 R4).
#
# **Presence, not absence.** The scheduler detects both in-process: a panic is
# caught (`scheduler.rs`, "job panicked") and `check_for_stalled_jobs` turns a
# hung job's silence into an `ERROR` line ("job appears stalled", in
# `scheduler_jobs.rs`). Nothing read that log. This does, from the host's own
# journal, where the `journald` logging driver already puts it, and posts
# `JobFailed{job=scheduler}` through post-metric.sh. The alarm is
# `sum(JobFailed) > 0` over 10 minutes, which clears by itself when the window
# rolls past the last post.
#
# **A cursor, so a line is posted once and none is missed.** The journal cursor
# of the last entry read is saved after each run, and the next run reads after
# it. Without one, a fixed window either posts the same line twice or misses one
# between runs. The first run, with no cursor, reads the last 10 minutes: the
# timer's interval. The cursor is saved only once the post has succeeded (or
# nothing matched), so a failed post is retried by the next run rather than lost.
#
# **What matches**, all three at once, at the top level of the application's JSON
# line (which it writes flattened, `main.rs`): `level` is `ERROR`, `target`
# starts with `server_game::app::scheduler`, and `message` is `job panicked` or
# `job appears stalled`. The message is kept in the filter so that some other
# `ERROR` the scheduler's modules come to log does not page; a new message that
# should is added here.
#
# **A quiet first run still leaves a cursor.** With no cursor and nothing in the
# window, the latest entry's cursor is saved anyway, so the next run reads from
# there and a line written in the gap is not missed. Only a journal with no
# entries at all leaves none.
#
# Usage: scheduler-alert.sh        (run by tile-lite-elite-scheduler-alert.timer)
#        CURSOR_FILE=... scheduler-alert.sh
#
# Exit (docs/1.10): 0 ran (posted or quiet);
#       2 could not read the journal (a technical, fundamental error; its
#         message tells it apart from post-metric.sh's own 2);
#       or, where a match could not be posted, post-metric.sh's own status (1, 2,
#       64, 70 or 75), with the cursor kept so the next run retries.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scheduler-alert.sh
       CURSOR_FILE=... scheduler-alert.sh

Reads the tle-server journal since the saved cursor (the last 10 minutes on
the first run), and posts JobFailed job=scheduler once if a line appeared
with level ERROR, a target starting server_game::app::scheduler, and the
message "job panicked" or "job appears stalled". Saves the new cursor.

Exits:
  0  ran: posted, or nothing matched
  1, 2, 64, 70, 75
     a match could not be posted: post-metric.sh's own status, passed
     through; the cursor is kept so the next run retries
     -> "error: scheduler failure seen but the metric did not post; will retry"
  2  could not read the journal (also post-metric.sh's 2; the message differs)
     -> "error: cannot read the journal"
EOF
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
CURSOR_FILE="${CURSOR_FILE:-$HOME/.tile-lite-elite-scheduler-cursor}"
FIRST_WINDOW="10 minutes ago"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

CURSOR=""
if [[ -s "$CURSOR_FILE" ]]; then CURSOR="$(< "$CURSOR_FILE")"; fi
TAIL_CURSOR="" # the latest entry's cursor, taken before a read by time

read_journal() {   # [journalctl option ...]
  journalctl CONTAINER_TAG=tle-server -o json --no-pager "$@" > "$OUT"
}

# A read by time, which has no cursor to start from. The latest entry's cursor
# is taken **first**: a line landing between the two reads is then inside the
# window read next, and is not lost to a cursor taken after it.
read_by_time() {
  TAIL_CURSOR="$(journalctl CONTAINER_TAG=tle-server -o json --no-pager -n 1 2>/dev/null \
    | python3 -I -c '
import json, sys
for line in sys.stdin:
    try:
        print(json.loads(line).get("__CURSOR", ""))
    except ValueError:
        pass' || true)"
  read_journal --since "$FIRST_WINDOW" \
    || { echo "error: cannot read the journal" >&2; exit 2; }
}

if [[ -n "$CURSOR" ]]; then
  if ! read_journal --after-cursor="$CURSOR"; then
    # A well-formed cursor whose entry has rotated away seeks to the nearest
    # entry and does not fail; one that is malformed does, and must not wedge
    # this for good: fall back to the first-run window and say so.
    echo "warning: the saved cursor is not usable; reading the last 10 minutes" >&2
    read_by_time
  fi
else
  read_by_time
fi

# Two lines out: the number of matching entries, then the cursor of the last
# entry read (empty when there were none).
RESULT="$(python3 -I -c '
import json
import sys

matched = 0
cursor = ""
for line in open(sys.argv[1]):
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    cursor = entry.get("__CURSOR") or cursor
    message = entry.get("MESSAGE")
    if not isinstance(message, str):
        continue
    try:
        event = json.loads(message)
    except ValueError:
        continue
    if (isinstance(event, dict)
            and event.get("level") == "ERROR"
            and str(event.get("target", "")).startswith("server_game::app::scheduler")
            and event.get("message") in ("job panicked", "job appears stalled")):
        matched += 1
print(matched)
print(cursor)
' "$OUT")"
MATCHED="$(sed -n 1p <<< "$RESULT")"
NEW_CURSOR="$(sed -n 2p <<< "$RESULT")"

# Reading by time and finding nothing: the cursor taken before the read, so the
# next run starts there rather than looking back over a window again.
if [[ -z "$NEW_CURSOR" ]]; then NEW_CURSOR="$TAIL_CURSOR"; fi

if [[ "$MATCHED" -gt 0 ]]; then
  STATUS=0
  "$HERE/post-metric.sh" JobFailed 1 job=scheduler || STATUS=$?
  if [[ "$STATUS" -ne 0 ]]; then
    echo "error: scheduler failure seen but the metric did not post; will retry" >&2
    exit "$STATUS"
  fi
  echo "posted JobFailed job=scheduler ($MATCHED matching lines)"
fi

if [[ -n "$NEW_CURSOR" ]]; then
  printf '%s\n' "$NEW_CURSOR" > "$CURSOR_FILE.new"
  mv "$CURSOR_FILE.new" "$CURSOR_FILE"
fi
