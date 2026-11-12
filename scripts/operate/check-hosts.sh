#!/usr/bin/env bash
set -euo pipefail

# check-hosts.sh — are rehearsal and production current, and alike?
#
# **#360 R2 and R3.** A kernel or libc installed and not running is not a fix,
# and rehearsal proves nothing about production if the kernel and the container
# runtime underneath differ. The read is the programme's shared
# `board-hosts.py` (programme docs/1.1), so this script and the weekly
# `host-currency` activity (programme docs/1.4) cannot disagree. The hosts are
# the `[hosts.*]` tables in `app-profile.toml`; `PROD_SSH_HOST` and
# `REHEARSAL_SSH_HOST` still replace their ssh names.
#
# Read-only: it reads over ssh and changes nothing. Rebooting or upgrading a
# host is the owner's call.
#
#   ./scripts/operate/check-hosts.sh            # the table and its findings
#   ./scripts/operate/check-hosts.sh --json
#
# Exit 0 current and alike, 1 a finding (it reports; you decide), 2 a host
# could not be read, 70 the profile is missing or broken.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$ROOT/programme/scripts/board/board-hosts.py" -C "$ROOT" "$@"
