#!/usr/bin/env bash
set -euo pipefail

# rehearsal-key.sh — the rehearsal access key, however it has to be obtained.
#
# Rehearsal is closed by the Caddyfile (#240): everything but `/health` answers
# 403 without the cookie, *before* the request reaches the application. So any
# tool that must reach rehearsal has to let itself in, and until now each one
# knew separately how — `check-rate-limits.sh` learned it in `fe0e48c` and the
# Rust example did not, which is #371.
#
# **One place knows, for the reason `shipping-paths.sh` gives about itself.**
# Two copies is how the same defect comes to exist twice, and this one decides
# whether a test suite is testing the application or the door.
#
#   KEY="$(scripts/rehearsal-key.sh)" || exit 1
#   curl -H "Cookie: rehearsal=$KEY" ...
#
# `REHEARSAL_ACCESS_KEY` short-circuits the ssh, which is what lets this point
# at another environment, or run where there is no ssh access.
# `REHEARSAL_SSH_HOST` names the host if it is not the configured alias.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: rehearsal-key.sh
       KEY="$(scripts/rehearsal-key.sh)" || exit 1

Prints rehearsal's access key on stdout, however it has to be
obtained: REHEARSAL_ACCESS_KEY if it is set, otherwise read from the
host's .env over ssh. One place knows, because two copies is how the
same defect comes to exist twice and this one decides whether a test
suite is testing the application or the door (#240, #371).

REHEARSAL_SSH_HOST names the host if it is not the configured alias.

Refuses (exit 1) when:
  - no key can be obtained by either route
    -> "rehearsal-key: no key. Set REHEARSAL_ACCESS_KEY, or check ssh
        access to <host>."
    A closed gate and a broken application refuse identically, so a
    suite that runs without the key reports the door as a defect.
EOF
  exit 0
fi

if [[ -n "${REHEARSAL_ACCESS_KEY:-}" ]]; then
  printf '%s\n' "$REHEARSAL_ACCESS_KEY"
  exit 0
fi

# `-n` so ssh does not eat the caller's stdin: this is routinely run inside a
# `while read` loop, and a git command that inherits the loop's stdin consumes
# the lines it has not read yet. The same trap deploy.sh records.
KEY="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 \
  "${REHEARSAL_SSH_HOST:-tile-lite-elite-rehearsal}" \
  "grep -m1 '^REHEARSAL_ACCESS_KEY=' ~/tile-lite-elite/.env | cut -d= -f2-" \
  2>/dev/null | tr -d '\r' || true)"

if [[ -z "$KEY" ]]; then
  echo "rehearsal-key: no key. Set REHEARSAL_ACCESS_KEY, or check ssh access to" >&2
  echo "               ${REHEARSAL_SSH_HOST:-tile-lite-elite-rehearsal}." >&2
  echo "               A closed gate and a broken application refuse identically." >&2
  exit 1
fi
printf '%s\n' "$KEY"
