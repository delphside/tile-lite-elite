#!/usr/bin/env bats

# migrate: `server --migrate-only` through TURPIN_COMPOSE, within 300 s.

setup() {
  load helpers
  common_setup
  COMPOSE="docker compose -p tile-lite-elite --project-directory /var/lib/turpin/x/deploys/4"
}

@test "refuses with no TURPIN_COMPOSE, then runs the migrations through it" {
  run "$HOOKS/migrate"
  assert_failure 1
  assert_output --partial "TURPIN_COMPOSE is not set"
  export TURPIN_COMPOSE="$COMPOSE"
  run "$HOOKS/migrate"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line "compose -p tile-lite-elite --project-directory /var/lib/turpin/x/deploys/4 run --rm server --migrate-only"
}

@test "refuses where the migrations fail" {
  export TURPIN_COMPOSE="$COMPOSE" STUB_DOCKER_RC=1
  run "$HOOKS/migrate"
  assert_failure 1
  assert_output --partial "the migrations failed"
}

@test "an image that ignores --migrate-only and keeps running is stopped at 300 s" {
  export TURPIN_COMPOSE="$COMPOSE" TIMEOUT_EXPIRES=1
  run "$HOOKS/migrate"
  assert_failure 1
  assert_output --partial "did not finish within 300s"
  run cat "$TIMEOUT_LOG"
  assert_line "300"
}
