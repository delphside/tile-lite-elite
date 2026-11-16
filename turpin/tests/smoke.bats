#!/usr/bin/env bats

# smoke: /health through Caddy on the host reports VERSION+ and a prefix of the
# SHA, within 60 s. A test that expects a refusal shortens the wait with
# TIMEOUT_REAL, which the `timeout` stub uses in place of 60.

setup() {
  load helpers
  common_setup
  export STUB_HEALTH='{"status":"ok","app_version":"0.10.2+0123456"}'
  export TURPIN_URL=https://tileliteelite.test
}

@test "refuses a stale container's version, then passes once the new one answers" {
  export STUB_HEALTH='{"app_version":"0.10.1+2bbb957"}' TIMEOUT_REAL=1
  run "$HOOKS/smoke"
  assert_failure 1
  assert_output --partial "did not report 0.10.2+0123456 within 60s"
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}'
  run "$HOOKS/smoke"
  assert_success
}

@test "refuses a version of the right number from another commit" {
  export STUB_HEALTH='{"app_version":"0.10.2+fffffff"}' TIMEOUT_REAL=1
  run "$HOOKS/smoke"
  assert_failure 1
}

@test "refuses a version with no build id" {
  export STUB_HEALTH='{"app_version":"0.10.2"}' TIMEOUT_REAL=1
  run "$HOOKS/smoke"
  assert_failure 1
}

@test "refuses where /health does not answer" {
  export STUB_CURL_RC=7 STUB_HEALTH= TIMEOUT_REAL=1
  run "$HOOKS/smoke"
  assert_failure 1
}

@test "asks for https://HOST/health with HOST resolved to this host, for Caddy's SNI" {
  run "$HOOKS/smoke"
  assert_success
  run cat "$CURL_LOG"
  assert_line --partial "--resolve tileliteelite.test:443:127.0.0.1 https://tileliteelite.test/health"
}

@test "uses preview's plain-HTTP address as it is" {
  export TURPIN_URL=http://localhost:8081
  run "$HOOKS/smoke"
  assert_success
  run cat "$CURL_LOG"
  assert_line --partial "http://localhost:8081/health"
  refute_line --partial "--resolve"
}

@test "with no url, takes the first name in SITE_ADDRESS from the environment's .env" {
  unset TURPIN_URL
  run "$HOOKS/smoke"
  assert_failure 1
  assert_output --partial "no SITE_ADDRESS"
  echo "SITE_ADDRESS=1.2.3.4.sslip.io, other.test" > "$TURPIN_STATE/.env"
  run "$HOOKS/smoke"
  assert_success
  run cat "$CURL_LOG"
  assert_line --partial "--resolve 1.2.3.4.sslip.io:443:127.0.0.1 https://1.2.3.4.sslip.io/health"
}

@test "refuses an address that is neither http nor https" {
  export TURPIN_URL=ftp://x.test
  run "$HOOKS/smoke"
  assert_failure 1
}

@test "is bounded at 60 s" {
  export TIMEOUT_EXPIRES=1
  run "$HOOKS/smoke"
  assert_failure 1
  assert_output --partial "within 60s"
  run cat "$TIMEOUT_LOG"
  assert_line "60"
}
