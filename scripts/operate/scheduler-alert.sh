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
# What matches: `level` is `ERROR` and `target` starts with
# `server_game::app::scheduler`. Both lines carry those at the top level of the
# JSON line, which the application writes flattened (`main.rs`).
#
# Usage: scheduler-alert.sh        (run by tile-lite-elite-scheduler-alert.timer)
#        CURSOR_FILE=... scheduler-alert.sh
#
# Exit: 0 ran (posted or quiet); 1 a match was found and could not be posted
#       (the cursor is kept, so the next run retries); 2 could not read the
#       journal.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scheduler-alert.sh
       CURSOR_FILE=... scheduler-alert.sh

Reads the tle-server journal since the saved cursor (the last 10 minutes on
the first run), and posts JobFailed job=scheduler once if any ERROR line
from server_game::app::scheduler* appeared. Saves the new cursor.

Exits:
  0  ran: posted, or nothing matched
  1  a match could not be posted; the cursor is kept so the next run retries
     -> "error: scheduler failure seen but the metric did not post; will retry"
  2  could not read the journal
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

read_journal() {   # [journalctl option ...]
  journalctl CONTAINER_TAG=tle-server -o json --no-pager "$@" > "$OUT"
}

if [[ -n "$CURSOR" ]]; then
  if ! read_journal --after-cursor="$CURSOR"; then
    # A cursor the journal no longer holds (rotated away) must not wedge this
    # for good: fall back to the first-run window and say so.
    echo "warning: the saved cursor is not in the journal; reading the last 10 minutes" >&2
    read_journal --since "$FIRST_WINDOW" || { echo "error: cannot read the journal" >&2; exit 2; }
  fi
else
  read_journal --since "$FIRST_WINDOW" || { echo "error: cannot read the journal" >&2; exit 2; }
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

if [[ "$MATCHED" -gt 0 ]]; then
  if ! "$HERE/post-metric.sh" JobFailed 1 job=scheduler; then
    echo "error: scheduler failure seen but the metric did not post; will retry" >&2
    exit 1
  fi
  echo "posted JobFailed job=scheduler ($MATCHED matching lines)"
fi

if [[ -n "$NEW_CURSOR" ]]; then
  printf '%s\n' "$NEW_CURSOR" > "$CURSOR_FILE.new"
  mv "$CURSOR_FILE.new" "$CURSOR_FILE"
fi
