#!/usr/bin/env bats

# deploy.sh's restore_after_failed_load: when loading the images or taking the
# snapshot fails, the server that was stopped for the snapshot is started
# again, and :latest points back at the images that were live.
#
# Before this, a failed snapshot ended the run under `set -e` with the server
# stopped and nothing to start it, so production stayed down until someone
# noticed.
#
# ssh is a stub that runs the remote script locally in a scratch directory,
# and docker is a stub on PATH that logs its arguments.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../deliver/deploy.sh"
  HOST_DIR="$BATS_TEST_TMPDIR/host"
  mkdir -p "$HOST_DIR/snapshots" "$BATS_TEST_TMPDIR/bin"
  DEPLOY_REMOTE_DIR="$HOST_DIR"
  SNAPSHOT_NAME="pre-0.10.2-abc1234-20261115T010000Z.tgz"
  SSH_OPTS=()
  REMOTE="stub"
  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  export DOCKER_LOG
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[[ "$*" == "compose start server" && -n "${DOCKER_START_FAILS:-}" ]] && exit 1
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  ssh() { local script="${*: -1}"; bash -c "$script"; }
}

@test "the recorded images become :latest again and the server is started" {
  printf 'server sha256:aaa\nweb sha256:bbb\n' > "$HOST_DIR/.pre-load-images"
  touch "$HOST_DIR/snapshots/$SNAPSHOT_NAME"
  run restore_after_failed_load
  assert_success
  assert_output --partial "running the version it had before"
  run cat "$DOCKER_LOG"
  assert_line "image tag sha256:aaa tile-lite-elite-server:latest"
  assert_line "image tag sha256:bbb tile-lite-elite-web:latest"
  assert_line "compose start server"
  [[ ! -e "$HOST_DIR/.pre-load-images" ]]
  [[ ! -e "$HOST_DIR/snapshots/$SNAPSHOT_NAME" ]]
}

# The run failed before the ids were written, so :latest never moved, and
# :previous may be an older generation that must not become :latest.
@test "with no recorded images nothing is retagged, and the server is still started" {
  run restore_after_failed_load
  assert_success
  run cat "$DOCKER_LOG"
  refute_line --partial "image tag"
  assert_line "compose start server"
}

@test "a server that will not start is reported loudly with the command to run" {
  DOCKER_START_FAILS=1
  export DOCKER_START_FAILS
  run restore_after_failed_load
  assert_output --partial "COULD NOT RESTART THE SERVER"
  assert_output --partial "docker compose start server"
}
