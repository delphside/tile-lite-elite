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
#      **This creates no accounts.** The body sent is `{}`, which the limiter
#      counts and the handler never sees — see the note at that check.
#   3. A refusal is one a client can act on: 429, Retry-After, and an
#      ApiError body — the contract the UI reads.
#   4. Logging in repeatedly from one address is refused. Also creates nothing:
#      it signs in as an account that does not exist, which costs Argon2 anyway.
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

# Rehearsal is behind the access gate (#240), which answers 403 to anything
# without the cookie — before the request reaches the application at all. That
# made every check here fail, and the third one lie: "login never refused,
# twenty attempts all passed" is what a broken rate limiter looks like, and it
# was twenty requests stopped at the door. A closed gate and a broken limiter
# refuse identically, and this script could not tell them apart. #286.
#
# So it lets itself in, rather than being waved through by an exemption: the
# key is the one `rehearsal-access.sh` wrote, and getting past the gate with it
# is part of what the run proves.
# The key lives on the rehearsal host, not here, so it is read the way
# `rehearsal-access.sh status` reads it. Set REHEARSAL_ACCESS_KEY to skip the
# ssh, or to point this at some other environment.
GATE_COOKIE=()
# Delegated to `rehearsal-key.sh` since #371: this knew how to get in and the
# Rust example did not, and one place knowing is the fix rather than a third
# copy of the ssh.
if [[ -z "${REHEARSAL_ACCESS_KEY:-}" ]]; then
  REHEARSAL_ACCESS_KEY="$("$(dirname "${BASH_SOURCE[0]}")/rehearsal-key.sh" 2>/dev/null || true)"
fi
if [[ -n "${REHEARSAL_ACCESS_KEY:-}" ]]; then
  GATE_COOKIE=(-H "Cookie: rehearsal=$REHEARSAL_ACCESS_KEY")
else
  say() { printf '  %s\n' "$*"; }
  say "warning: no rehearsal access key — every request will be refused by the"
  say "         gate, and a refusal at the door looks exactly like a broken"
  say "         limiter. Run ./scripts/rehearsal-access.sh grant first."
fi

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
    "${GATE_COOKIE[@]+"${GATE_COOKIE[@]}"}" \
    -X POST "$TARGET$path" -d "$body" || echo "000"
}

echo "==> Rate limits on $TARGET"
echo "    caller $BUSY (as Caddy sees it: this machine)"
echo

# 2. Registration, from one address, repeatedly.
#
# **The body is deliberately `{}`, not a real registration.** The limiter is a
# tower layer on the route (`throttle::apply`), so it counts a request before
# the `Json` extractor ever sees the body — an unparseable body is answered 422
# until the bucket empties and 429 after, reaching the limit at exactly the
# attempt a valid payload would.
#
# Measured 2026-08-30 against a server on the defaults (2/min, burst 3):
# `422 422 422 429 429 429 429 429`, and `select count(*) from players` still 0.
#
# That is the point. Eight real registrations left three or four accounts on
# rehearsal every run and twenty-two had accumulated in four days (#128, #148,
# #242) — in the environment whose whole purpose is to resemble production. The
# accounts were never the subject of the test, only a side effect of reaching
# the limit. The login check below has always worked this way, against an
# account that does not exist.
#
# The status before the refusal is asserted rather than ignored. Without that, a
# registration route answering 404 or 500 on every attempt would still pass this
# check the moment the limiter fired.
registered_refusal=""
registered_wrong=""
for attempt in $(seq 1 8); do
  status="$(post_status /auth/register "$BUSY" '{}')"
  case "$status" in
    429) registered_refusal="$attempt"; break ;;
    422) : ;;
    *)   registered_wrong="$status"; break ;;
  esac
done
if [[ -n "$registered_wrong" ]]; then
  say "FAIL registration answered $registered_wrong, expected 422 for an unparseable body"
  say "     the route is not behaving, and a limiter firing would have hidden it"
  FAILURES=$((FAILURES + 1))
elif [[ -n "$registered_refusal" ]]; then
  say "ok   registration refused after $registered_refusal from one address"
else
  say "FAIL registration never refused — eight attempts from one address all passed"
  FAILURES=$((FAILURES + 1))
fi

# 1. Health, while that address is being refused. Deliberately **without** the
#    gate cookie: /health is the gate's one exemption, so an unauthenticated
#    200 here is part of what this proves.
check "health still answers while a caller is being refused" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$TARGET/health" || echo 000)"

# 3. The refusal is one a client can act on. #78 reads exactly this: a status
#    it can tell apart from "the server is down", a wait it can show, and a
#    message in the shape every other error uses. tower_governor's own default
#    body is plain text, so this is checking a deliberate override.
#
#    Headers and body both come back on stdout — `-D -` for the one, `-o -` for
#    the other — and are split on the blank line between them. This used to write
#    the body to a file under `/tmp` and remove it on the next line, which an
#    interrupt between the two would have skipped. Same reasoning as the
#    registration check above: not creating it beats remembering to remove it.
RESPONSE="$(curl -s -D - -o - --max-time 10 \
  -H 'content-type: application/json' -H "x-forwarded-for: $BUSY" \
  "${GATE_COOKIE[@]+"${GATE_COOKIE[@]}"}" \
  -X POST "$TARGET/auth/register" \
  -d '{}' || true)"
# The first blank line ends the header block. The `\r` is optional so this reads
# a raw HTTP/1.1 response and one curl has already normalised alike.
REFUSAL="$(printf '%s\n' "$RESPONSE" | sed -n '1,/^\r\{0,1\}$/p')"
BODY="$(printf '%s\n' "$RESPONSE" | sed '1,/^\r\{0,1\}$/d')"
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
