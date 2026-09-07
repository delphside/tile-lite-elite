#!/usr/bin/env bash
# inbox-hook.sh — SessionStart summary of GitHub activity, for Claude's context.
#
# Wraps scripts/inbox.sh. Lives in .claude/ (gitignored) rather than scripts/,
# because it is about how Claude is driven, not about the project.
#
# **A summary, not a replay.** The full seven-day output is ~25KB, most of it
# Claude's own comments being read back to itself. This emits which issues have
# comments from Steve and what opened or closed; `./scripts/inbox.sh` gives the
# detail on demand.
#
# Note the counts are only reliable from 2026-08-16, when Claude started
# footering everything it posts (#169). Before that, an unmarked comment may be
# either party's, so older entries over-count Steve.
#
# Never fails a session: every error path exits 0 with no output, because a
# broken inbox must not stop work starting.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 0
command -v gh > /dev/null 2>&1 || exit 0

RAW="$(./scripts/inbox.sh 7 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')" || exit 0
[[ -z "$RAW" ]] && exit 0

SUMMARY="$(printf '%s\n' "$RAW" | awk '
  /^#[0-9]+ / { issue = $0; next }
  /^  > /     { if (!(issue in count)) order[++k] = issue; count[issue]++; next }
  /^OPENED OR CLOSED/ { tail = 1; next }
  tail && /^  #/ { events[++e] = $0 }
  END {
    # Capped. A release week closes thirty issues at once, and an unbounded
    # summary of a busy week is the same wall of text this was meant to avoid.
    if (k) {
      print "Issues with comments from Steve (newest last):"
      start = k > 12 ? k - 11 : 1
      if (start > 1) printf "  ...%d earlier\n", start - 1
      for (i = start; i <= k; i++) printf "  %s  [%d]\n", order[i], count[order[i]]
    }
    if (e) {
      if (k) print ""
      printf "Opened or closed (%d; newest last):\n", e
      start = e > 10 ? e - 9 : 1
      if (start > 1) printf "  ...%d earlier\n", start - 1
      for (i = start; i <= e; i++) print events[i]
    }
  }
')"

# **What is waiting on Claude, and what does not add up** — #347 R2. The two
# tools that answer this were wired to nothing: `actions.py --claude` was in no
# hook at all, and `check-transitions.sh` was reachable only by hand or through
# `verify.sh`, where it is a `note` and `CLAUDE.md`:82 says to trust the exit
# status rather than read the output. Following the process exactly meant never
# seeing either.
#
# **In parallel**, because three sequential calls measured 16s against a 30s
# timeout and a slow GitHub would eat the margin. Each is separately guarded:
# one failing leaves the others, and all of them failing leaves the inbox
# summary, which is what this hook did before.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( timeout 20 ./scripts/actions.py --claude 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$TMP/actions" ) &
( timeout 20 ./scripts/check-transitions.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$TMP/trans" ) &
wait

# Only the findings. A clean run says "every open issue has done the work its
# field claims", which is worth nothing in context and would be repeated into
# every later turn of the session.
TRANS="$(grep -E '^\s+#[0-9]+' "$TMP/trans" 2>/dev/null | head -20 || true)"
ACTIONS="$(sed '/^\s*$/d' "$TMP/actions" 2>/dev/null | head -40 || true)"

EXTRA=""
[[ -n "$ACTIONS" ]] && EXTRA="$EXTRA"$'\n\n'"Waiting on you (./scripts/actions.py --claude for the detail):"$'\n'"$ACTIONS"
[[ -n "$TRANS" ]] && EXTRA="$EXTRA"$'\n\n'"Further along than their content supports (./scripts/check-transitions.sh):"$'\n'"$TRANS"

[[ -z "$SUMMARY" && -z "$EXTRA" ]] && exit 0

printf '%s' "$SUMMARY$EXTRA" | python3 -c '
import sys, json
t = sys.stdin.read().strip()
if t:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext":
            "GitHub activity in the last 7 days. Run ./scripts/inbox.sh for the detail.\n\n" + t,
    }}))
' 2>/dev/null || exit 0
