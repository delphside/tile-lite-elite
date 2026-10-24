#!/usr/bin/env bats

# The Caddyfile's rehearsal access gate (#240, #530), run against a real Caddy.
# Only the gate block is lifted out of the Caddyfile (between its two marker
# comments) and put in front of a plain "open" response on a local port, so
# what is tested is the text that ships, without certificates or the rest of
# the site. Requests name the host in a Host header.
#
# The cases that matter are a host whose .env has no key (docker-compose.yml
# then passes a sentinel): it must refuse every device, the unlock path
# included, while /health and production's hostnames stay open.
#
# CI sets REQUIRE_CADDY=1 so a missing binary is a failure there; elsewhere
# the file skips.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  if ! command -v caddy > /dev/null; then
    [[ -z "${REQUIRE_CADDY:-}" ]] || fail "REQUIRE_CADDY is set but caddy is not installed"
    skip "caddy is not installed"
  fi
  CADDYFILE="$BATS_TEST_DIRNAME/../../Caddyfile"
  PORT=$((20000 + RANDOM % 20000))
  CONF="$BATS_TEST_TMPDIR/Caddyfile"
  {
    printf '{\n\tadmin off\n\tauto_https off\n}\n:%s {\n\troute {\n' "$PORT"
    sed -n '/--- Rehearsal access control/,/--- end rehearsal access control/p' "$CADDYFILE"
    printf '\t\trespond "open" 200\n\t}\n}\n'
  } > "$CONF"
}

teardown() {
  [[ -z "${CADDY_PID:-}" ]] || kill "$CADDY_PID" 2> /dev/null || true
}

# start_caddy [KEY]: KEY unset leaves the variable out of the environment,
# which is what a Compose file without a default would hand Caddy; any other
# value, empty included, is set as given.
start_caddy() {
  if [[ $# -eq 0 ]]; then
    env -u REHEARSAL_ACCESS_KEY caddy run --config "$CONF" --adapter caddyfile \
      > "$BATS_TEST_TMPDIR/caddy.log" 2>&1 &
  else
    REHEARSAL_ACCESS_KEY="$1" caddy run --config "$CONF" --adapter caddyfile \
      > "$BATS_TEST_TMPDIR/caddy.log" 2>&1 &
  fi
  CADDY_PID=$!
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && return 0
    sleep 0.2
  done
  cat "$BATS_TEST_TMPDIR/caddy.log" >&2
  fail "caddy did not start"
}

# req HOST PATH [COOKIE]: prints the status code, then the Set-Cookie header
# if there was one.
req() {
  local args=(-s -D - -o /dev/null -H "Host: $1")
  [[ -z "${3:-}" ]] || args+=(-H "Cookie: $3")
  curl "${args[@]}" "http://127.0.0.1:$PORT$2" \
    | tr -d '\r' | awk 'NR==1 {print $2} tolower($0) ~ /^set-cookie:/ {print}'
}

REH=rehearsal.tileliteelite.com
PROD=tileliteelite.com

@test "a keyed host: the unlock path sets the cookie, the cookie opens, nothing else does" {
  start_caddy abc123
  run req $REH /unlock/abc123
  assert_line --index 0 302
  assert_line --partial 'rehearsal=abc123'
  run req $REH /games
  assert_output 403
  run req $REH /games "rehearsal=wrong"
  assert_output 403
  run req $REH /games "rehearsal=abc123"
  assert_output 200
  run req $REH /unlock/wrong
  assert_output 403
}

@test "a keyed host: /health and production's hostname are open without a cookie" {
  start_caddy abc123
  run req $REH /health
  assert_output 200
  run req $PROD /games
  assert_output 200
}

# The three ways a host can have no key: the sentinel Compose supplies, an
# empty value, and the variable missing altogether.
check_keyless() {
  run req $REH /unlock/no-rehearsal-key-configured
  assert_output 403
  run req $REH /unlock/
  assert_output 403
  run req $REH /games "rehearsal=no-rehearsal-key-configured"
  assert_output 403
  run req $REH /games "rehearsal="
  assert_output 403
  run req $REH /
  assert_output 403
  run req $REH /health
  assert_output 200
  run req $PROD /games
  assert_output 200
}

@test "a host with the sentinel key refuses every device, the unlock path included" {
  start_caddy no-rehearsal-key-configured
  check_keyless
}

@test "a host with an empty key refuses every device" {
  start_caddy ""
  check_keyless
}

@test "a host with no key variable refuses every device" {
  start_caddy
  check_keyless
}
