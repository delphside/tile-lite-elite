#!/usr/bin/env bats

# The @api matcher in Caddyfile and Caddyfile.preview (#519), run against a
# real Caddy. Only the matcher line is lifted out of each file and put in
# front of two plain responses, "api" for what the matcher proxies and "spa"
# for what falls through to the web client, so what is tested is the text
# that ships. Every route the server offers to players must answer "api".
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
  PORT=$((20000 + RANDOM % 20000))
}

teardown() {
  [[ -z "${CADDY_PID:-}" ]] || kill "$CADDY_PID" 2> /dev/null || true
}

# start_caddy FILE: serves FILE's @api matcher on a local port.
start_caddy() {
  local matcher conf="$BATS_TEST_TMPDIR/Caddyfile"
  matcher="$(grep -E '^[[:space:]]*@api path ' "$BATS_TEST_DIRNAME/../../$1")"
  [[ "$(wc -l <<< "$matcher")" -eq 1 ]] || fail "$1 should have one @api matcher"
  {
    printf '{\n\tadmin off\n\tauto_https off\n}\n:%s {\n\troute {\n' "$PORT"
    printf '%s\n' "$matcher"
    printf '\t\trespond @api "api" 200\n\t\trespond "spa" 200\n\t}\n}\n'
  } > "$conf"
  caddy run --config "$conf" --adapter caddyfile > "$BATS_TEST_TMPDIR/caddy.log" 2>&1 &
  CADDY_PID=$!
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0
    sleep 0.2
  done
  cat "$BATS_TEST_TMPDIR/caddy.log" >&2
  fail "caddy did not start"
}

req() {
  curl -s "http://127.0.0.1:$PORT$1"
}

check_matcher() {
  start_caddy "$1"
  for path in /health /engines /engines/stockfish/stats /engines/stockfish/rating-history \
    /auth/login /games /games/abc /players/abc/stats /invitations/abc/preview \
    /dictionaries/sowpods; do
    assert_equal "$path $(req "$path")" "$path api"
  done
  # Not the server's to answer through the proxy: the admin routes are
  # loopback-only, and anything else is the web client's.
  for path in / /admin/users /enginesx /assets/app.js; do
    assert_equal "$path $(req "$path")" "$path spa"
  done
}

@test "Caddyfile proxies every player route, the engine sub-routes included" {
  check_matcher Caddyfile
}

@test "Caddyfile.preview proxies every player route, the engine sub-routes included" {
  check_matcher Caddyfile.preview
}
