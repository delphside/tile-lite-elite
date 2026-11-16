#!/usr/bin/env bats

# pre-deploy: refuses where the database is ahead of the pulled image's schema
# label, passes where it is not, and bounds each Docker call at 30 s.

setup() {
  load helpers
  common_setup
  with_image
  export STUB_SCHEMA_LABEL=7
}

@test "refuses a database ahead of the image, then passes once it is not" {
  export STUB_CONTAINER=abc123 STUB_APPLIED=8
  run "$HOOKS/pre-deploy"
  assert_failure 1
  assert_output --partial "migration 8"
  assert_output --partial "up to 7"
  export STUB_APPLIED=7
  run "$HOOKS/pre-deploy"
  assert_success
}

@test "reads the database in the running server, found by its Compose labels" {
  export STUB_CONTAINER=abc123 STUB_APPLIED=5
  run "$HOOKS/pre-deploy"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line --partial "label=com.docker.compose.project=tile-lite-elite"
  assert_line --partial "label=com.docker.compose.service=server"
  assert_line --partial "exec abc123 sh -c"
}

@test "with no server running, reads it in a one-off container of the pulled image, the volume read-only" {
  export STUB_CONTAINER= STUB_APPLIED=5
  run "$HOOKS/pre-deploy"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line --partial "run --rm -v tile-lite-elite-data:/data:ro --entrypoint sh $TURPIN_IMAGE_SERVER"
}

@test "preview reads its own volume" {
  export TURPIN_ROLE=preview STUB_CONTAINER= STUB_APPLIED=5
  run "$HOOKS/pre-deploy"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line --partial "-v tile-lite-elite-preview-data:/data:ro"
}

@test "no database yet passes, with no volume or with an empty one" {
  export STUB_CONTAINER= STUB_VOLUME_RC=1
  run "$HOOKS/pre-deploy"
  assert_success
  run cat "$DOCKER_LOG"
  refute_line --partial "run --rm"
  export STUB_VOLUME_RC=0 STUB_APPLIED=none
  run "$HOOKS/pre-deploy"
  assert_success
  assert_output --partial "no database yet"
}

@test "refuses where the image carries no schema label, since it cannot judge" {
  export STUB_SCHEMA_LABEL= STUB_CONTAINER=abc123 STUB_APPLIED=5
  run "$HOOKS/pre-deploy"
  assert_failure 1
  assert_output --partial "no org.tileliteelite.schema label"
}

@test "refuses where the image is not named" {
  unset TURPIN_IMAGE_SERVER
  run "$HOOKS/pre-deploy"
  assert_failure 1
  assert_output --partial "TURPIN_IMAGE_SERVER is not set"
}

@test "a Docker call that outlasts 30 s refuses" {
  export TIMEOUT_EXPIRES=1
  run "$HOOKS/pre-deploy"
  assert_failure 1
  assert_output --partial "did not finish within 30s"
  run cat "$TIMEOUT_LOG"
  assert_line "30"
}
