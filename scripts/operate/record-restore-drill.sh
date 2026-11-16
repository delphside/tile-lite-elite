#!/usr/bin/env bash
# Record on the production host that a restore drill just happened (#608, #224).
#
# The drill itself (`restore-backup.sh`) runs on the development machine, which
# has no instance principal and will not be given one. So the last step of the
# runbook calls this over ssh, and the host keeps the time:
#
#   ssh tile-lite-elite 'scripts/operate/record-restore-drill.sh'
#
# The disk timer (`post-disk-metrics.sh`) reads the file daily-ish and posts
# `RestoreDrillAgeDays`; the alarm is that age above 100. A file rather than a
# metric posted from here, because an absence alarm cannot run to 100 days.
#
# The file is `~/.tile-lite-elite-restore-drill`, beside the other state the
# operate scripts keep in the home directory, and holds the UTC time as epoch
# seconds. `DRILL_FILE=...` overrides it.
#
# Exit: 0 recorded; 2 could not write the file.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: record-restore-drill.sh
       DRILL_FILE=... record-restore-drill.sh

Records now (UTC, epoch seconds) as the time of the last restore drill, in
~/.tile-lite-elite-restore-drill. Run on the production host, as the last
step of the drill.

Exits:
  0  recorded
  2  could not write the file
     -> "error: cannot record the drill in <file>"
EOF
  exit 0
fi

DRILL_FILE="${DRILL_FILE:-$HOME/.tile-lite-elite-restore-drill}"
NOW="$(date -u +%s)"

# Written beside and renamed, so a reader never sees half a number.
if ! { printf '%s\n' "$NOW" > "$DRILL_FILE.new" && mv "$DRILL_FILE.new" "$DRILL_FILE"; }; then
  echo "error: cannot record the drill in $DRILL_FILE" >&2
  exit 2
fi
echo "recorded the restore drill at $NOW ($(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ))"
