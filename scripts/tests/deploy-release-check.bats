#!/usr/bin/env bats

# deploy.sh's Release Check announcement (#310). This code runs after
# production is already serving the new version, so an abort here would turn a
# successful deploy into a failed one, which is why the cases include GitHub
# being unreachable and returning nothing.
#
# Sources deploy.sh with DEPLOY_SH_FUNCTIONS_ONLY=1 rather than copying the
# logic. A test that re-implements what it checks proves only that two copies
# agree.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../application/deliver/deploy.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${GH_FAIL:-}" ] && exit 1
cat "$GH_OUT"
STUB
  chmod +x "$BIN/gh"
  PATH="$BIN:$PATH"
  export GH_OUT="$BATS_TEST_TMPDIR/out"
  printf '  #214  Build once, deploy the same artefact\n' > "$GH_OUT"
}

@test "a production release names them, and says what to do with them" {
  run announce_release_checks 1 production
  assert_output --partial '#214'
  assert_output --partial 'take the label off'
}

# The three cases where it must say nothing at all.
@test "a preview deploy says nothing" {
  run announce_release_checks 1 preview
  assert_output ""
}

@test "a rehearsal deploy says nothing" {
  run announce_release_checks 1 rehearsal
  assert_output ""
}

@test "a non-release deploy says nothing" {
  run announce_release_checks 0 production
  assert_output ""
}

@test "nothing labelled means no output" {
  : > "$GH_OUT"
  run announce_release_checks 1 production
  assert_output ""
}

# It runs after production is already live, so it must never be the thing that
# fails the deploy. Run in a shell of its own under deploy.sh's
# `set -euo pipefail`: bats' `run`, like the old suite's `|| rc=$?`, turns
# errexit off, and then a failing `gh` cannot abort anything. Removing the
# `|| true` that guards it passed both until 2026-09-27.
@test "GitHub being unreachable still exits 0" {
  export GH_FAIL=1
  run bash -c 'set -euo pipefail
    DEPLOY_SH_FUNCTIONS_ONLY=1 source "$1"
    announce_release_checks 1 production' _ "$BATS_TEST_DIRNAME/../application/deliver/deploy.sh"
  assert_success
}
