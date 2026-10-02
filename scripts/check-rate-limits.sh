#!/usr/bin/env bash
set -euo pipefail

# check-rate-limits.sh — does the running server refuse a caller who asks too
# often, and keep answering everybody else?
#
# This is the technical test that stands in for user testing on a change with
# nothing to look at. Run it against the **rehearsal host**, which is why that
# environment exists: same shape as production (2 vCPU, 954 MB), production's
# data, and nobody watching. Numbers tuned on a development machine are
# meaningless — the limits are there to protect a box a fraction its size.
#
#   ./scripts/check-rate-limits.sh                     # the rehearsal host
#   ./scripts/check-rate-limits.sh http://localhost:8081   # or preview
#
# What it asserts, in the order the layers are applied:
#
#   1. /health never refuses, however hard anything else is being refused.
#      deploy.sh smoke-tests this, so a health check that fails under load
#      would roll back a release that was merely busy.
#   2. Registering repeatedly from one address is refused with 429.
#   3. A refusal is one a client can act on: 429, Retry-After, and an
#      ApiError body — the contract the UI reads.
#   4. Logging in repeatedly from one address is refused.
#
# **What it deliberately cannot check: that one caller's allowance is not
# another's.** Caddy replaces X-Forwarded-For with the address the connection
# actually came from, so every request from this machine is genuinely one
# caller however the header is set. An earlier version of this script sent from
# a second, "quiet" address and asserted it was unaffected; through Caddy that
# was the same caller, and the check failed on its first rehearsal run —
# correctly, and for a reason that has nothing to do with the limits.
#
# The separation is covered in-process instead, by
# `one_callers_allowance_is_not_anothers` in app/throttle.rs, where two keys
# can actually exist. See docs/changes/25-rate-limiting.md.
#
# It does not assert the numbers are *right*. It asserts the shape holds:
# refusal rather than a growing queue, per-caller rather than global, and
# health exempt. Whether 2 registrations a minute is the correct figure is a
# judgement about real use, and #28's load tests are where that gets measured.

TARGET="${1:-${REHEARSAL_URL:-https://129.151.84.183.sslip.io}}"
FAILURES=0

say() { printf '  %s\n' "$*"; }

check() {
  local what="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    say "ok   $what"
  else
    say "FAIL $what — wanted $expected, got $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

# A distinct address per run, so a re-run is not refused by the buckets the
# last one filled. `X-Forwarded-For` is what the server keys on, and it is
# trusted only because Caddy is the sole ingress — see `app/throttle.rs`.
RUN="$(( RANDOM % 250 + 1 ))"
BUSY="203.0.113.$RUN"

post_status() {
  local path="$1" address="$2" body="$3"
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'content-type: application/json' \
    -H "x-forwarded-for: $address" \
    -X POST "$TARGET$path" -d "$body" || echo "000"
}

echo "==> Rate limits on $TARGET"
echo "    caller $BUSY (as Caddy sees it: this machine)"
echo

# 2. Registration, from one address, repeatedly.
registered_refusal=""
for attempt in $(seq 1 8); do
  name="ratecheck-$RUN-$attempt"
  status="$(post_status /auth/register "$BUSY" \
    "{\"display_name\":\"$name\",\"email\":\"$name@example.com\",\"password\":\"correct horse battery staple\",\"stay_logged_in\":false}")"
  if [[ "$status" == "429" ]]; then
    registered_refusal="$attempt"
    break
  fi
done
if [[ -n "$registered_refusal" ]]; then
  say "ok   registration refused after $registered_refusal from one address"
else
  say "FAIL registration never refused — eight attempts from one address all passed"
  FAILURES=$((FAILURES + 1))
fi

# 1. Health, while that address is being refused.
check "health still answers while a caller is being refused" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$TARGET/health" || echo 000)"

# 3. The refusal is one a client can act on. #78 reads exactly this: a status
#    it can tell apart from "the server is down", a wait it can show, and a
#    message in the shape every other error uses. tower_governor's own default
#    body is plain text, so this is checking a deliberate override.
REFUSAL="$(curl -s -D - -o /tmp/ratecheck-body.$$ --max-time 10 \
  -H 'content-type: application/json' -H "x-forwarded-for: $BUSY" \
  -X POST "$TARGET/auth/register" \
  -d '{"display_name":"ratecheck-shape","email":"s@example.com","password":"correct horse battery staple","stay_logged_in":false}' || true)"
BODY="$(cat /tmp/ratecheck-body.$$ 2>/dev/null || true)"
rm -f /tmp/ratecheck-body.$$
if printf '%s' "$REFUSAL" | grep -qi '^HTTP/[0-9.]* 429'; then
  say "ok   the refusal is 429"
  if printf '%s' "$REFUSAL" | grep -qi '^retry-after:'; then
    say "ok   and carries Retry-After, so a client can say how long"
  else
    say "FAIL the refusal has no Retry-After header"
    FAILURES=$((FAILURES + 1))
  fi
  if printf '%s' "$BODY" | grep -q '"message"'; then
    say "ok   and an ApiError body, not tower_governor's plain text"
  else
    say "FAIL the refusal body is not ApiError — a client would show 'something went wrong'"
    say "     got: $(printf '%s' "$BODY" | head -c 120)"
    FAILURES=$((FAILURES + 1))
  fi
else
  say "FAIL expected a 429 to inspect, got: $(printf '%s' "$REFUSAL" | head -1)"
  FAILURES=$((FAILURES + 1))
fi

# 4. Login, which costs Argon2 whether or not the credentials are real.
login_refusal=""
for attempt in $(seq 1 20); do
  status="$(post_status /auth/login "$BUSY" \
    '{"display_name":"nobody-at-all","password":"wrong"}')"
  if [[ "$status" == "429" ]]; then
    login_refusal="$attempt"
    break
  fi
done
if [[ -n "$login_refusal" ]]; then
  say "ok   login refused after $login_refusal from one address"
else
  say "FAIL login never refused — twenty attempts from one address all passed"
  FAILURES=$((FAILURES + 1))
fi

echo
if (( FAILURES > 0 )); then
  echo "$FAILURES check(s) failed" >&2
  exit 1
fi
echo "All rate-limit checks passed."
