#!/usr/bin/env bash
# inbox-hook.sh — SessionStart summary of GitHub activity, for Claude's context.
#
# Wraps scripts/programme/board/board-inbox.py. Lives in .claude/ (gitignored) rather than scripts/,
# because it is about how Claude is driven, not about the project.
#
# **A summary, not a replay.** The full seven-day output is ~25KB, most of it
# Claude's own comments being read back to itself. This emits which issues have
# comments from Steve and what opened or closed; `./scripts/programme/board/board-inbox.py` gives the
# detail on demand.
#
# Note the counts are only reliable from 2026-08-16, when Claude started
# footering everything it posts (#169). Before that, an unmarked comment may be
# either party's, so older entries over-count Steve.
#
# Never fails a session: every error path exits 0 with no output, because a
# broken inbox must not stop work starting.
#
# **Fast, because it reads a cache (#452).** The three board calls take ~48s,
# and a session whose first message was sent while the hook ran appears to have
# started with no hook at all (session 60541916, 2026-10-01, no record of any
# kind). So the slow work is `--build`, run detached and written to
# .claude/.inbox-cache; the SessionStart hook only reads it and says how old
# it is. Modes:
#   (none)               SessionStart: emit the cache, refresh it behind us
#   --build              compute the summary and write the cache (locked)
#   --refresh-if-stale   start a detached --build if the cache is old; the
#                        Stop hook calls this so the cache follows the work
#   --backstop SID       UserPromptSubmit: print the cache as plain text if
#                        session SID never had it delivered, then mark it
# Every run is logged to .claude/.inbox-hook.log (start, end, session id) so
# a session with no hook can be told from a hook that ran and was ignored.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 0
CACHE=.claude/.inbox-cache
LOCK=.claude/.inbox-build.lock
LOG=.claude/.inbox-hook.log
DELIVERED=.claude/.inbox-delivered
STALE_SECS="${INBOX_STALE_SECS:-600}"
MODE="${1:-}"

log() { printf '%s %s pid=%s %s\n' "$(date -u +%FT%TZ)" "$MODE" "$$" "$*" >> "$LOG" 2> /dev/null || true; }

cache_age() { echo $(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) )); }

# Plain text, with the cache's age so a stale one is never mistaken for live.
cache_text() {
  printf 'GitHub activity in the last 7 days (from a cache %s min old; ./scripts/programme/board/board-inbox.py for current detail).\n\n' "$(( $(cache_age) / 60 ))"
  cat "$CACHE"
}

mark_delivered() {
  [[ -n "${1:-}" ]] || return 0
  mkdir -p "$DELIVERED" && : > "$DELIVERED/$1"
  find "$DELIVERED" -type f -mtime +7 -delete 2> /dev/null || true
}

start_build() {
  nohup setsid "$0" --build > /dev/null 2>&1 < /dev/null &
}

case "$MODE" in
  --refresh-if-stale)
    [[ -f "$CACHE" ]] && (( $(cache_age) < STALE_SECS )) && exit 0
    start_build; exit 0 ;;
  --backstop)
    SID="${2:-}"
    [[ -n "$SID" && ! -e "$DELIVERED/$SID" ]] || exit 0
    log "sid=$SID backstop: no delivery on record"
    if [[ -s "$CACHE" ]]; then
      cache_text; mark_delivered "$SID"; log "sid=$SID backstop delivered"
    else
      start_build   # nothing to say yet; the next turn will have it
    fi
    exit 0 ;;
esac

# SessionStart, and --build, below. Only SessionStart has a hook payload on stdin.
SID=""
if [[ "$MODE" != "--build" && ! -t 0 ]]; then
  SID="$(timeout 2 cat 2>/dev/null | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)"
fi
log "sid=${SID:-?} start"

emit_json() {
  printf '%s' "$1" | python3 -c '
import sys, json
t = sys.stdin.read().strip()
if t:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": t,
    }}))
' 2>/dev/null
}

if [[ "$MODE" != "--build" && -s "$CACHE" ]]; then
  emit_json "$(cache_text)" && mark_delivered "$SID"
  (( $(cache_age) >= STALE_SECS )) && start_build
  log "sid=${SID:-?} end (from cache)"
  exit 0
fi

# --build, or SessionStart with no cache at all: do the slow work.
command -v gh > /dev/null 2>&1 || exit 0
if [[ "$MODE" == "--build" ]]; then
  # One build at a time; a lock older than five minutes is a dead build's.
  find "$LOCK" -maxdepth 0 -mmin +5 -exec rmdir {} \; 2> /dev/null || true
  mkdir "$LOCK" 2> /dev/null || exit 0
  trap 'rmdir "$LOCK" 2> /dev/null' EXIT
fi

RAW="$(./scripts/programme/board/board-inbox.py 7 --no-colour 2>/dev/null)" || exit 0
[[ -z "$RAW" ]] && exit 0

# **The to-do half is `board-inbox.py --open`** (#454), run with the others below:
# the owner's comments Claude has not answered, of any age. This awk keeps only
# what opened or closed, which is news rather than work.
SUMMARY="$(printf '%s\n' "$RAW" | awk '
  /^OPENED OR CLOSED/ { tail = 1; next }
  tail && /^  #/ { events[++e] = $0 }
  END {
    # Capped. A release week closes thirty issues at once, and an unbounded
    # summary of a busy week is the same wall of text this was meant to avoid.
    if (e) {
      printf "Opened or closed (%d; newest last):\n", e
      start = e > 10 ? e - 9 : 1
      if (start > 1) printf "  ...%d earlier\n", start - 1
      for (i = start; i <= e; i++) print events[i]
    }
  }
')"


# **What is waiting on Claude, and what does not add up** — #347 R2. The two
# tools that answer this were wired to nothing: the actions report was in no
# hook at all, and the transition check was reachable only by hand or through
# `verify.sh`, where it is a `note` and `CLAUDE.md`:82 says to trust the exit
# status rather than read the output. Following the process exactly meant never
# seeing either.
#
# **Both moved to the board model on 2026-09-19** — `board-actions.py --claude`
# (R1's mirror) and `board-check.py` (R4). This hook kept calling the retired
# `check-transitions.sh` for the length of one commit, and because every path
# here is guarded it lost that half **silently**: exactly the failure the
# guards exist to prevent at session start, arriving as a missing signal rather
# than an error.
#
# **In parallel**, because three sequential calls measured 16s against a 30s
# timeout and a slow GitHub would eat the margin. Each is separately guarded:
# one failing leaves the others, and all of them failing leaves the inbox
# summary, which is what this hook did before.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [[ "$MODE" == "--build" ]] && rmdir "$LOCK" 2> /dev/null' EXIT
( timeout 25 ./scripts/programme/board/board-actions.py --claude --no-colour 2>/dev/null > "$TMP/actions" ) &
( timeout 25 ./scripts/programme/board/board-check.py --no-colour 2>/dev/null > "$TMP/trans" ) &
( timeout 10 ./scripts/programme/board/board-practices.py 2>/dev/null > "$TMP/practices" ) &
( timeout 25 ./scripts/programme/board/board-inbox.py --open --no-colour 2>/dev/null > "$TMP/open" ) &
wait

# Only the findings. A clean run says nothing is missing, which is worth
# nothing in context and would be repeated into every later turn of the
# session. R4 prints a finding's issue at column 0, where check-transitions.sh
# indented it — a difference that silently matched nothing for one commit.
TRANS="$(grep -E '^#[0-9]+' "$TMP/trans" 2>/dev/null | head -20 || true)"
ACTIONS="$(grep -E '^  #[0-9]+' "$TMP/actions" 2>/dev/null | head -40 || true)"
# #407 R3: read every session, since a session start is not a repetition of
# the previous one — there is nothing to debounce, unlike the weekly digest
# `programme-activities.yml` sends the owner during an absence.
PRACTICES="$(grep -E 'OVERDUE|never logged' "$TMP/practices" 2>/dev/null || true)"

# **Reports from the scheduled workflows.** Owner, 2026-09-27: "can you add a
# hook so you notice a new report?" The workflows report by writing an issue
# as the github-actions bot and editing it on later runs, which leaves no
# comment for the summary above to count. board-inbox.py lists them in their
# own section; this passes that section on, and nothing when it is empty.
REPORTS="$(printf '%s\n' "$RAW" | sed -n '/^REPORTS FROM THE SCHEDULED WORKFLOWS/,/^$/p' \
  | grep -E '^  #[0-9]+' || true)"

# The to-do list first. `^#` is an issue; the sentence for an empty list and the
# `...N earlier` line are not findings, so a quiet board adds nothing.
OPEN="$(grep -E '^(#[0-9]+|  > |\.\.\.[0-9]+ earlier)' "$TMP/open" 2>/dev/null || true)"

EXTRA=""
[[ -n "$OPEN" ]] && EXTRA="$EXTRA"$'\n\n'"Waiting on Claude: comments from Steve not yet answered, of any age (./scripts/programme/board/board-inbox.py --open --all):"$'\n'"$OPEN"
[[ -n "$REPORTS" ]] && EXTRA="$EXTRA"$'\n\n'"For Claude to read: reports from the scheduled workflows, opened, updated or closed (./scripts/programme/board/board-inbox.py):"$'\n'"$REPORTS"
[[ -n "$ACTIONS" ]] && EXTRA="$EXTRA"$'\n\n'"Waiting on Claude: actions on the board (./scripts/programme/board/board-actions.py --claude for the detail):"$'\n'"$ACTIONS"
[[ -n "$TRANS" ]] && EXTRA="$EXTRA"$'\n\n'"For Claude to fix: incomplete for their type and step (./scripts/programme/board/board-check.py):"$'\n'"$TRANS"
[[ -n "$PRACTICES" ]] && EXTRA="$EXTRA"$'\n\n'"Programme activities overdue, whose move is the activity's owner in docs/5.3 (./scripts/programme/board/board-practices.py, docs/5.3):"$'\n'"$PRACTICES"

[[ -z "$SUMMARY" && -z "$EXTRA" ]] && exit 0

# Written whole and moved into place, so a reader never sees half a cache.
printf '%s\n' "$SUMMARY$EXTRA" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
if [[ "$MODE" == "--build" ]]; then
  log "build end"
else
  emit_json "GitHub activity in the last 7 days. Run ./scripts/programme/board/board-inbox.py for the detail.

$SUMMARY$EXTRA" && mark_delivered "$SID"
  log "sid=${SID:-?} end (built)"
fi
exit 0
