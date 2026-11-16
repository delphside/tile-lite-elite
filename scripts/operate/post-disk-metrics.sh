#!/usr/bin/env bash
# Post the host's disk and restore-drill figures (#608, #224 R2).
#
# Run every 15 minutes by tile-lite-elite-disk.timer, on a timer of its own so
# that the nightly units dying does not silence the disk alarm, and the reverse.
# Two metrics, both posted through post-metric.sh:
#
#   DiskFreePercent mount=/    the free share of the filesystem, 0 to 100
#   RestoreDrillAgeDays        whole days since record-restore-drill.sh ran
#
# **The drill's age is posted here because an absence alarm cannot run to 100
# days.** The host records the drill's time and posts its age; the alarm is a
# threshold, above 100. With no drill ever recorded, as on a rebuilt host, it
# posts 9999, so the alarm fires instead of staying silent. An unreadable record
# is treated the same way, with a warning. Both metrics come from this timer, so
# a sixth alarm watches for `DiskFreePercent` going absent.
#
# Both posts are attempted whatever the first does, so one failing cannot hide
# the other.
#
# Exit: 0 both posted; 1 a post failed (the other was still tried);
#       2 could not measure the disk.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: post-disk-metrics.sh
       MOUNT=/ DRILL_FILE=... post-disk-metrics.sh

Posts DiskFreePercent (dimension mount=<MOUNT>, default /) and
RestoreDrillAgeDays (9999 when no drill is recorded).

Exits:
  0  both posted
  1  a post failed; the other was still attempted
  2  could not measure the disk
     -> "error: cannot read free space for <mount>"
EOF
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
MOUNT="${MOUNT:-/}"
DRILL_FILE="${DRILL_FILE:-$HOME/.tile-lite-elite-restore-drill}"
NO_DRILL_DAYS=9999

# Free share from available and total bytes, to one decimal. `avail` is what an
# unprivileged process can use, which is what fills first.
FREE="$(df --output=avail,size -B1 "$MOUNT" 2>/dev/null \
  | awk 'NR == 2 && $2 > 0 { printf "%.1f", $1 * 100 / $2 }')" || FREE=""
[[ -n "$FREE" ]] || { echo "error: cannot read free space for $MOUNT" >&2; exit 2; }

AGE="$NO_DRILL_DAYS"
if [[ -r "$DRILL_FILE" ]]; then
  RECORDED="$(< "$DRILL_FILE")"
  if [[ "$RECORDED" =~ ^[0-9]+$ ]]; then
    NOW="$(date -u +%s)"
    AGE=$(( (NOW - RECORDED) / 86400 ))
    (( AGE >= 0 )) || AGE=0
  else
    echo "warning: $DRILL_FILE does not hold epoch seconds; posting $NO_DRILL_DAYS" >&2
  fi
fi

STATUS=0
"$HERE/post-metric.sh" DiskFreePercent "$FREE" "mount=$MOUNT" || STATUS=1
"$HERE/post-metric.sh" RestoreDrillAgeDays "$AGE" || STATUS=1
exit "$STATUS"
