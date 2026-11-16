#!/usr/bin/env bats

# scripts/operate/profile.d/tile-lite-elite-sa.sh: `sa` finds the server by its
# Compose labels and runs the admin CLI in it with docker exec.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
[[ "$1" != ps ]] || { [[ -z "${STUB_CONTAINER:-}" ]] || echo "$STUB_CONTAINER"; }
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../operate/profile.d/tile-lite-elite-sa.sh"
}

@test "sa says so, and fails, where no server container runs; then runs the CLI once one does" {
  run sa players list
  assert_failure 1
  assert_output --partial "no running tile-lite-elite server container"
  export STUB_CONTAINER=abc123
  run sa players list
  assert_success
  run cat "$DOCKER_LOG"
  assert_line "exec -i abc123 tile-lite-elite-admin players list"
}

@test "sa finds the container by the Compose project and service labels, not a compose file" {
  export STUB_CONTAINER=abc123
  run sa
  assert_success
  run cat "$DOCKER_LOG"
  assert_line "ps -q --filter label=com.docker.compose.project=tile-lite-elite --filter label=com.docker.compose.service=server"
  refute_line --partial "compose -f"
}

@test "the file is installed as mode 0644 and sourced, so it is not executable here" {
  [[ ! -x "$BATS_TEST_DIRNAME/../operate/profile.d/tile-lite-elite-sa.sh" ]]
}
