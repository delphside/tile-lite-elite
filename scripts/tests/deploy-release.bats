#!/usr/bin/env bats

# deploy.sh's GitHub Release step. This code runs after production is already
# serving the new version, so an abort here would turn a successful deploy into
# a failed one. It sources deploy.sh with DEPLOY_SH_FUNCTIONS_ONLY=1 rather than
# copying the pipeline: a test that re-implements what it checks proves only
# that two copies agree.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  DEPLOY="$BATS_TEST_DIRNAME/../application/deliver/deploy.sh"
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$DEPLOY"
  # A scratch repository whose tags are the whole input, and a gh that records
  # the command line it was given instead of reaching GitHub.
  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\necho "$@" >> "$GH_CALLS"\nexit "${GH_EXIT:-0}"\n' > "$BIN/gh"
  chmod +x "$BIN/gh"
  export GH_CALLS="$BATS_TEST_TMPDIR/calls"; : > "$GH_CALLS"
  export PATH="$BIN:$PATH"
}

tag() { local t; for t in "$@"; do git -C "$REPO_DIR" tag "$t"; done; }

# The cases that matter are the ones where it must not abort: an unguarded
# pipeline that matches nothing exits non-zero under pipefail.
@test "previous_release_tag: no tags, or only its own, yields nothing" {
  assert_equal "$(previous_release_tag prod-0.7.1)" ""
  tag prod-0.7.1
  assert_equal "$(previous_release_tag prod-0.7.1)" ""
}

@test "previous_release_tag: the newest predecessor, sorted numerically" {
  tag prod-0.7.1 prod-0.6.12 prod-0.7.0
  assert_equal "$(previous_release_tag prod-0.7.1)" 0.7.0
  tag prod-0.10.0
  assert_equal "$(previous_release_tag prod-0.7.1)" 0.10.0
}

@test "previous_release_tag: a redeploy's suffix and non-version tags are ignored" {
  tag prod-0.7.1 prod-0.10.0 prod-0.10.0-20260101T000000Z prod-preview prod-0.7
  assert_equal "$(previous_release_tag prod-0.7.1)" 0.10.0
}

@test "the first release ever passes no start tag" {
  publish_release prod-0.7.1 0.7.1 > /dev/null
  assert_equal "$(cat "$GH_CALLS")" "release create prod-0.7.1 --generate-notes --verify-tag --title 0.7.1"
}

@test "a predecessor becomes --notes-start-tag" {
  tag prod-0.7.0
  publish_release prod-0.7.1 0.7.1 > /dev/null
  assert_equal "$(cat "$GH_CALLS")" \
    "release create prod-0.7.1 --generate-notes --verify-tag --title 0.7.1 --notes-start-tag prod-0.7.0"
}

# A redeploy tag would claim a changelog that already exists.
@test "a redeploy publishes nothing, and says why" {
  tag prod-0.7.0
  run publish_release prod-0.7.1-20260101T000000Z 0.7.1
  assert_equal "$(cat "$GH_CALLS")" ""
  assert_output --partial redeploy
}

# The whole point: production is already serving by the time this runs. In a
# shell of its own under deploy.sh's `set -euo pipefail`, because `run` and
# `|| status=$?` both turn errexit off, and then nothing can abort.
@test "a failed release does not fail the deploy, and prints the command to run by hand" {
  export GH_EXIT=1
  run bash -c 'set -euo pipefail
    DEPLOY_SH_FUNCTIONS_ONLY=1 source "$1"
    publish_release prod-0.7.1 0.7.1' _ "$DEPLOY"
  assert_success
  assert_output --partial "gh release create prod-0.7.1"
}
