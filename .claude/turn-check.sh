#!/usr/bin/env bash
# turn-check.sh — new GitHub comments from Steve, injected at the start of a turn.
#
# Owner, 2026-08-19: *"When do you notice the 'Not approved' comment?"* Before
# this, the honest answer was: at the next session start, or when told. Nothing
# prompted a look mid-session — the same lazy-sweep failure #166 is about, one
# level up.
#
# A turn is the only moment Claude exists, so this runs on `UserPromptSubmit`:
# waking now implies looking.
#
# **Throttled.** At most one API call every 90 seconds, so a fast exchange does
# not pay for a check per message. State is one timestamp file in .claude/,
# which is gitignored — this is Claude's own bookkeeping, not the project's.
#
# **Silent when there is nothing.** Output is injected into the model's context,
# so anything printed on a quiet turn is noise in every later turn too.
#
# Never fails a turn: every path exits 0.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 0
STATE=".claude/.turn-check-state"

# `--reseed` records the current state without reporting. `--reseed-bodies`
# records only the pull request body hashes and leaves the comment timestamp
# alone — that is what the `Stop` hook runs, so a body Claude edited during a
# turn is recorded at the end of it and never announced back on the next one.
# A full `--reseed` would also swallow comments Steve wrote while the turn ran.
#
# `--print-filter` prints the jq filter and exits, so the part of this script
# that has broken twice can be tested against a fixture without calling GitHub.
RESEED=0
BODIES_ONLY=0
PRINT_FILTER=0
[[ "${1:-}" == "--reseed" ]] && RESEED=1
# Records everything Claude may have changed during a turn — pull request
# bodies *and* issue fields — without touching the comment clock. Both have the
# same failure if they are not recorded here: Claude sets a `Decision State`,
# and the next turn reports it back as though the owner had. The name is kept
# because `settings.json` is gitignored and invoking it differently would mean
# a by-hand change on every machine.
[[ "${1:-}" == "--reseed-bodies" || "${1:-}" == "--reseed-fields" ]] && { RESEED=1; BODIES_ONLY=1; }
[[ "${1:-}" == "--print-filter" ]] && PRINT_FILTER=1

NOW="$(date -u +%s)"
if [[ -f "$STATE" ]]; then
  LAST_RUN="$(stat -c %Y "$STATE" 2>/dev/null || echo 0)"
  (( ! RESEED && ! PRINT_FILTER && NOW - LAST_RUN < 90 )) && exit 0
  SINCE="$(cat "$STATE" 2>/dev/null)"
else
  SINCE=""
fi
[[ -z "$SINCE" ]] && SINCE="$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

command -v gh > /dev/null || exit 0

# Claude's own comments are excluded **by author**. This used to test the body
# for the string "Typed by Claude", written when both of us posted as the same
# GitHub user and a marker in the text was the only thing to go on. Since #206
# Delivery 2 there are two accounts, and on 2026-09-03 a check of the thirty
# most recent comments found the marker on **none** of them: every comment
# Claude had written qualified as Steve's. The author is the fact; the marker
# was a convention nothing enforced.
ME="$(cat .claude/.gh-login 2>/dev/null)"
if [[ -z "$ME" ]]; then
  ME="$(timeout 10 gh api user --jq .login 2>/dev/null)"
  [[ -n "$ME" ]] && printf '%s' "$ME" > .claude/.gh-login
fi

# The `[deploy.sh]` test stays, and is not redundant with the author filter:
# the owner runs production deploys himself now, so those comments are written
# by *his* account and the author filter would let them through.
# `gh api` takes exactly one argument after --jq and has no --arg of its own,
# so the login is substituted into the filter rather than bound as a jq
# variable. Writing `--jq --arg me "$ME"` fails with "accepts 1 arg(s),
# received 4", and because this whole pipeline sends stderr to /dev/null it
# fails *silently*: the check would report nothing, forever, and look calm.
# An empty $ME falls back to a sentinel that matches no login, so a failed
# lookup over-reports rather than going quiet.
FILTER='.[] | select(.user.login != "__ME__")
            | select((.body | test("^\\[deploy.sh\\]")) | not)
            | "#\(.issue_url | split("/") | last)  \(.updated_at[11:16])  \((.body | gsub("\n"; " "))[0:160])"'
FILTER="${FILTER/__ME__/${ME:-__no_such_login__}}"
if (( PRINT_FILTER )); then printf '%s\n' "$FILTER"; exit 0; fi

NEW="$(timeout 15 gh api "repos/{owner}/{repo}/issues/comments?since=$SINCE&sort=updated&direction=asc&per_page=30" \
  --jq "$FILTER" 2>/dev/null)"

# Pull request bodies are a review surface now — Steve writes notes under the
# checklist items rather than in a comment thread (2026-08-19). A body edit
# produces no comment and no event this can poll for, so bodies are hashed and
# compared. `updated_at` would be simpler and wrong: it also moves for labels,
# commits and comments, and would cry wolf on every one.
HASHES=".claude/.body-hashes"
CURRENT="$(timeout 15 gh pr list --state open --limit 30 --json number,body \
  --jq '.[] | "\(.number) \(.body | @base64)"' 2>/dev/null \
  | while read -r num body; do printf '%s %s\n' "$num" "$(printf '%s' "$body" | md5sum | cut -d' ' -f1)"; done)"

EDITED=""
if [[ -f "$HASHES" && -n "$CURRENT" ]]; then
  while read -r num hash; do
    old="$(grep -E "^$num " "$HASHES" 2>/dev/null | awk '{print $2}')"
    [[ -n "$old" && "$old" != "$hash" ]] && EDITED="$EDITED  PR #$num body edited — read the review checklist"$'\n'
  done <<< "$CURRENT"
fi
[[ -n "$CURRENT" ]] && printf '%s\n' "$CURRENT" > "$HASHES"

# **Fields, because a field is how the owner says it is Claude's turn.** On
# 2026-09-07 he moved #332 to `Decided` and #337 to `Feedback Provided` while
# Claude worked, and neither was noticed: this script watched comments and
# bodies, and reported PR #341's body twice the same afternoon. `Decision State`
# is a field, and a field change produces no comment and no body edit. #347 R1.
#
# Only the two that say *whose turn it is*. `Workstream` or `Priority` moving is
# bookkeeping; `Decision State` reaching `Decided` means applying is due.
FIELDS=".claude/.field-state"
NWO="$(cat .claude/.gh-repo 2>/dev/null)"
if [[ -z "$NWO" ]]; then
  NWO="$(timeout 10 gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [[ -n "$NWO" ]] && printf '%s' "$NWO" > .claude/.gh-repo
fi

FIELDS_NOW=""
if [[ -n "$NWO" ]]; then
  FIELDS_NOW="$(timeout 15 gh api graphql -f query="{repository(owner:\"${NWO%%/*}\",name:\"${NWO##*/}\"){issues(first:100,states:OPEN){nodes{number issueFieldValues(first:20){nodes{... on IssueFieldSingleSelectValue{field{... on IssueFieldSingleSelect{name}} name}}}}}}}" \
    --jq '.data.repository.issues.nodes[]
          | . as $i
          | ([$i.issueFieldValues.nodes[]?|select(.field.name=="Decision State")|.name][0] // "-") as $d
          | ([$i.issueFieldValues.nodes[]?|select(.field.name=="Phase")|.name][0] // "-") as $p
          | "\($i.number)\t\($d)\t\($p)"' 2>/dev/null)"
fi

MOVED=""
if [[ -f "$FIELDS" && -n "$FIELDS_NOW" ]]; then
  while IFS=$'\t' read -r num d p; do
    [[ -n "$num" ]] || continue
    old_line="$(grep -P "^$num\t" "$FIELDS" 2>/dev/null || true)"
    # A new issue has no previous line. Reporting it as a transition would
    # announce every issue Claude just raised, so absence is not a change.
    [[ -n "$old_line" ]] || continue
    old_d="$(printf '%s' "$old_line" | cut -f2)"
    old_p="$(printf '%s' "$old_line" | cut -f3)"
    [[ "$old_d" != "$d" ]] && MOVED="$MOVED  #$num  Decision State: $old_d -> $d"$'\n'
    [[ "$old_p" != "$p" ]] && MOVED="$MOVED  #$num  Phase: $old_p -> $p"$'\n'
  done <<< "$FIELDS_NOW"
fi
[[ -n "$FIELDS_NOW" ]] && printf '%s\n' "$FIELDS_NOW" > "$FIELDS"

# **The long-session sweep** — #347 R3. `SessionStart` runs the full sweep once,
# and a session that lasts hours would otherwise never look again. Today's ran
# from morning to evening.
#
# **A pointer, not a payload.** What was missing is the *trigger to look*, so
# this emits two counts and the command to run. Repeating the full listing every
# two hours would put the same wall of text into context repeatedly, which is
# the failure `inbox-hook.sh`'s own summary was written to avoid.
#
# **Guarded to 12s and silent on timeout.** It runs alongside the calls above
# against the hook's own budget, and a sweep that could delay a turn is worse
# than one that occasionally skips: the next turn past the interval tries again.
SWEEP=".claude/.sweep-state"
SWEEP_EVERY="${TURN_CHECK_SWEEP_SECS:-7200}"
SWEPT=""
if (( ! RESEED && ! PRINT_FILTER )); then
  LAST_SWEEP=0
  [[ -f "$SWEEP" ]] && LAST_SWEEP="$(stat -c %Y "$SWEEP" 2>/dev/null || echo 0)"
  if (( NOW - LAST_SWEEP >= SWEEP_EVERY )); then
    SDIR="$(mktemp -d)"
    ( timeout 12 ./scripts/actions.py --claude 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -cE '^ +-' > "$SDIR/a" ) 2>/dev/null &
    ( timeout 12 ./scripts/check-transitions.sh 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -cE '^\s+#[0-9]+' > "$SDIR/t" ) 2>/dev/null &
    wait
    A="$(cat "$SDIR/a" 2>/dev/null || echo 0)"; T="$(cat "$SDIR/t" 2>/dev/null || echo 0)"
    rm -rf "$SDIR"
    # Only when there is something. A sweep that reports "0 and 0" every two
    # hours is noise with a schedule.
    if [[ "$A" =~ ^[0-9]+$ && "$T" =~ ^[0-9]+$ ]] && (( A + T > 0 )); then
      SWEPT="  $A action(s) waiting on you, $T issue(s) further along than their content supports"$'\n'
      SWEPT="$SWEPT  ./scripts/actions.py --claude   ./scripts/check-transitions.sh"$'\n'
    fi
    touch "$SWEEP"
  fi
fi

# --reseed-bodies stops here: bodies and fields are recorded, the comment clock
# is not touched, and nothing is reported.
(( BODIES_ONLY )) && exit 0

date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE"

(( RESEED )) && exit 0
[[ -z "$NEW" && -z "$EDITED" && -z "$MOVED" && -z "$SWEPT" ]] && exit 0

echo "New on GitHub since the last check (Steve's, not yours) — reply where it was said, not here:"
[[ -n "$NEW" ]] && echo "$NEW"
[[ -n "$EDITED" ]] && printf '%s' "$EDITED"
# Last, and labelled, because it is the one that calls for an act rather than a
# reply: `Decided` means applying is due, `Feedback Provided` means a response
# and the written decision are owed.
[[ -n "$MOVED" ]] && { echo "Fields moved — this is the owner saying it is your turn:"; printf '%s' "$MOVED"; }
[[ -n "$SWEPT" ]] && { echo "Periodic sweep:"; printf '%s' "$SWEPT"; }
