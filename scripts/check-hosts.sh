#!/usr/bin/env bash
set -euo pipefail

# check-hosts.sh — do rehearsal and production still look like each other?
#
# **#360 R3.** The two drifted for weeks on facts that take a second to read,
# and nothing said so. Rehearsal's whole value is being production-shaped: a
# release proven there proves nothing about production if the kernel and the
# container runtime underneath it are different.
#
# **It also answers R2**, which is the half that is easy to miss: a kernel or
# libc that is installed and not running is not a fix. `unattended-upgrades`
# writes `/var/run/reboot-required` and nothing acts on it, so a host can be
# fully patched on disk and still running the vulnerable code — for months.
#
# Read-only, and deliberately so. It reads three facts over ssh and changes
# nothing; rebooting a host is the owner's call, and doing it to production
# without asking is the kind of thing that is not mine to decide.
#
#   ./scripts/check-hosts.sh
#
# Exit 1 when they diverge or a reboot is pending, so a caller can gate on it.
# It still only reports: the remedy is a sentence at the end, never an action.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: check-hosts.sh

Reads the kernel, the Docker version and whether a reboot is pending
from production and rehearsal, and compares them. Read-only: it never
changes a host. See the header comment above for why (#360 R2, R3).

Refuses (exit 2) when:
  - either host cannot be read over ssh within 40 seconds
    -> "could not read <host>"
    A closed door and a dead host refuse identically here, so check
    ssh access before reading this as an outage.

Reports a finding (exit 1) when:
  - the kernels differ
    -> "!! different kernels — a release proven on rehearsal was
        proven on another kernel"
  - the Docker versions differ
    -> "!! different Docker versions — the runtime under the image is
        not the same runtime"
  - either host has /var/run/reboot-required
    -> "!! <host> has a reboot pending — installed fixes are on disk
        and not running (#360 R2)"

Exit 1 is a finding, not a fault: rehearsal may lead production
deliberately while an upgrade is being proven there. It reports and
you decide.

Exit 0 when the two agree and neither is waiting to reboot.
EOF
  exit 0
fi

PROD_HOST="${PROD_SSH_HOST:-tile-lite-elite}"
REHEARSAL_HOST="${REHEARSAL_SSH_HOST:-tile-lite-elite-rehearsal}"

# One ssh per host rather than one per fact. Three round trips to each turns a
# two-second check into eight, and a check nobody waits for is a check nobody
# runs. `-n` for the reason deploy.sh records: ssh inherits the caller's stdin.
read_host() {
  timeout 40 ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$1" '
    printf "%s\t%s\t%s\n" \
      "$(uname -r)" \
      "$(docker --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1)" \
      "$([ -f /var/run/reboot-required ] && echo yes || echo no)"
  ' 2>/dev/null
}

echo "==> Hosts, against each other"

if ! PROD="$(read_host "$PROD_HOST")" || [ -z "$PROD" ]; then
  echo "  could not read $PROD_HOST" >&2; exit 2
fi
if ! REH="$(read_host "$REHEARSAL_HOST")" || [ -z "$REH" ]; then
  echo "  could not read $REHEARSAL_HOST" >&2; exit 2
fi

IFS=$'\t' read -r P_KERNEL P_DOCKER P_REBOOT <<< "$PROD"
IFS=$'\t' read -r R_KERNEL R_DOCKER R_REBOOT <<< "$REH"

printf '  %-12s %-24s %-10s %s\n' "" "kernel" "docker" "reboot pending"
printf '  %-12s %-24s %-10s %s\n' "production" "$P_KERNEL" "$P_DOCKER" "$P_REBOOT"
printf '  %-12s %-24s %-10s %s\n' "rehearsal"  "$R_KERNEL" "$R_DOCKER" "$R_REBOOT"
echo

FINDINGS=0
if [ "$P_KERNEL" != "$R_KERNEL" ]; then
  echo "  !! different kernels — a release proven on rehearsal was proven on another kernel"
  FINDINGS=$((FINDINGS + 1))
fi
if [ "$P_DOCKER" != "$R_DOCKER" ]; then
  echo "  !! different Docker versions — the runtime under the image is not the same runtime"
  FINDINGS=$((FINDINGS + 1))
fi
for pair in "production:$P_REBOOT" "rehearsal:$R_REBOOT"; do
  if [ "${pair#*:}" = "yes" ]; then
    echo "  !! ${pair%%:*} has a reboot pending — installed fixes are on disk and not running (#360 R2)"
    FINDINGS=$((FINDINGS + 1))
  fi
done

if [ "$FINDINGS" -eq 0 ]; then
  echo "  the two agree, and neither is waiting to reboot"
  exit 0
fi

echo
echo "  $FINDINGS finding(s). Rehearsal may lead production deliberately while an"
echo "  upgrade is being proven there — #360 R1 allows exactly that, and this"
echo "  cannot tell a deliberate lead from a drift. It reports; you decide."
exit 1
