#!/usr/bin/env bash
# The nightly log check on the production host (#174).
#
# Reads the day's journal, validates it against the schema `docs/4.4.7` declares,
# writes exceptions to its own log, and posts a `JobSucceeded` metric **only on a
# clean run**.
#
# **It creates nothing and touches nothing.** Owner, 2026-08-21: *"the production
# check should just check the production logs, and write its own exception log."*
# The rare events a week of production would not show are covered elsewhere — the
# regression suite drives them in CI, which is where driving belongs.
#
# **The metric is why this alerts at all.** An alarm on its absence
# fires for a dirty run *and* for this script crashing, the timer never being
# enabled, the host being down, or the credential expiring. An alarm waiting for
# a failure message only ever catches the failure somebody thought of.
#
# Usage: check-log-hygiene-nightly.sh      (run by tile-lite-elite-log-check.timer)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SINCE="${SINCE:-yesterday}"
EXCEPTIONS="${EXCEPTIONS:-$HOME/log-hygiene-exceptions.log}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

# `-o cat` gives the message as written — our JSON line and nothing of
# journald's own framing around it.
if journalctl CONTAINER_TAG=tle-server -o cat --since "$SINCE" \
   | python3 "$HERE/check-log-hygiene.py" --source production - > "$OUT" 2>&1; then
  printf '%s clean\n' "$STAMP" >> "$EXCEPTIONS"
  # A failed post fails the run: the exceptions file is written and the alarm
  # would fire anyway, but the failure should show in the unit's status.
  "$HERE/post-metric.sh" JobSucceeded 1 job=logcheck
  exit 0
fi

# A dirty run appends the whole report and does **not** post the metric, which
# is what makes the alarm fire. The exceptions accumulate here rather than being
# mailed: a channel that fires rarely and is read never is not a control, and
# `status.sh` surfaces a non-empty file where somebody is already looking.
{
  printf '%s EXCEPTIONS\n' "$STAMP"
  sed 's/^/    /' "$OUT"
  printf '\n'
} >> "$EXCEPTIONS"

cat "$OUT" >&2
exit 1
