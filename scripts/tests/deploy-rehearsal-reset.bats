#!/usr/bin/env bats

# `deploy-rehearsal.sh reset`: the guard, and that it does not fall through to
# a deploy (#252 R4).
#
# The destructive half is not exercised: it runs `docker compose down -v` over
# ssh, and a test that stubs both proves the stub. What is worth pinning is that
# it refuses a host that is not rehearsal, and that `reset` never reaches
# deploy.sh. A verb that silently deployed instead of resetting, or reset
# production instead of rehearsal, are the two ways this can be badly wrong.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  REAL="$BATS_TEST_DIRNAME/../application/deliver/deploy-rehearsal.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/scripts"
  # Nothing outward may be reached in a refusal; if it is, it says so.
  for c in ssh scp curl docker; do
    printf '#!/usr/bin/env bash\necho "REACHED %s" >&2\nexit 0\n' "$c" > "$D/bin/$c"
    chmod +x "$D/bin/$c"
  done
  # A copy of the script beside a wrong target file, which is the only way the
  # host can be production: rehearsal-target.sh exports DEPLOY_HOST
  # unconditionally, so a caller cannot set it from outside. The first version
  # of this test tried and the guard never fired.
  mkdir -p "$D/scripts/application/deliver"
  cp "$REAL" "$D/scripts/application/deliver/"
  printf '#!/usr/bin/env bash\necho "REACHED deploy.sh" >&2\n' > "$D/scripts/application/deliver/deploy.sh"
  chmod +x "$D/scripts/application/deliver/deploy.sh"
}

reset_against() {   # the host the target file wrongly points at
  cat > "$D/scripts/application/deliver/rehearsal-target.sh" <<TARGET
export DEPLOY_ENV=rehearsal
export DEPLOY_HOST=$1
export DEPLOY_USER=ubuntu
export DEPLOY_SSH_KEY=/dev/null
export DEPLOY_REMOTE_DIR=tile-lite-elite
export TARGET_URL=https://example.invalid
TARGET
  PATH="$D/bin:$PATH" run "$D/scripts/application/deliver/deploy-rehearsal.sh" reset
}

@test "production by IP is refused, and nothing is run against it" {
  reset_against 129.151.69.246
  assert_output --partial 'refusing to reset'
  refute_output --partial 'REACHED'
}

@test "production by hostname is refused" {
  reset_against tileliteelite.com
  assert_output --partial 'refusing to reset'
  refute_output --partial 'REACHED'
}

# ssh is a stub, so nothing is destroyed; what is asserted is that the real
# rehearsal host gets past the guard, and that reset never becomes a deploy.
@test "the rehearsal host is not refused, says what it destroys, and never reaches deploy.sh" {
  reset_against 129.151.84.183
  refute_output --partial 'refusing to reset'
  assert_output --partial 'including any seeded production data'
  refute_output --partial 'REACHED deploy.sh'
}

@test "the reset branch exits rather than falling through" {
  run bash -c "awk '/if \\[\\[ \"\\\$\\{1:-\\}\" == \"reset\" \\]\\]/,/^fi\$/' '$REAL' | grep -c 'exit 0'"
  assert_output 1
}

# At least once, not exactly once: the script says it in its header and again
# in --help (#329 R3), and an exact count made the second look like a regression.
@test "the usage mentions reset" {
  run grep -q 'deploy-rehearsal.sh reset' "$REAL"
  assert_success
}
