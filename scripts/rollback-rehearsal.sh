#!/usr/bin/env bash
set -euo pipefail

# rollback-rehearsal.sh — rollback.sh pointed at the rehearsal host.
#
# This is the one that matters. rollback.sh was proven by hand against
# production in the 2026-08-01 drill, but rehearsing it needs a host you can
# destroy without consequence — which is the reason the rehearsal
# environment exists at all (issue #13).
#
#   ./scripts/rollback-rehearsal.sh              # list what's available
#   ./scripts/rollback-rehearsal.sh <snapshot>   # database + images back

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/rehearsal-target.sh
. "$HERE/rehearsal-target.sh"
exec "$HERE/rollback.sh" "$@"
