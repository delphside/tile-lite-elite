#!/usr/bin/env bash
# programme-hook.sh <hook> [args...]: runs the programme's Claude hook of that name
# from the programme/ submodule (settings.json names this, not the hook).
#
# A Claude hook never fails the session, so when the submodule is not initialised
# this says so in one line and exits 0, where a bare path to a missing file would
# print "No such file" for every prompt and tool call and say nothing of why.
# Standard input and the arguments go through, as a hook reads them.
hook="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/programme/.claude/hooks/$1"
if [ ! -x "$hook" ]; then
  echo "The programme submodule is not initialised, so $1 did not run: run git submodule update --init"
  exit 0
fi
shift
exec "$hook" "$@"
