#!/usr/bin/env bats

# deploy.sh's post-deploy behaviour: once production is swapped, a failing step
# is reported and the run continues (D41, #321).
#
# 0.7.2 is the case this exists for. The version bump's commit was refused by
# the pre-commit image rule and, being unguarded under `set -e`, ended the
# script, so the milestone was never settled and announce_release_checks never
# ran, after every success line had already printed.
#
# The property under test is that a later step still runs after an earlier one
# fails. post_deploy is called directly, not through `run`, because what it
# records is a variable in this shell.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../application/deliver/deploy.sh"
  DEPLOYED_VERSION="0.7.2"
  POST_DEPLOY_FAILED=()
  ERR="$BATS_TEST_TMPDIR/err"
}

@test "a step that succeeds returns 0 and records nothing" {
  rc=0; post_deploy "a working step" "nothing to do" true || rc=$?
  assert_equal "$rc" 0
  assert_equal "${#POST_DEPLOY_FAILED[@]}" 0
}

@test "a step that fails returns non-zero and is recorded by name" {
  rc=0; post_deploy "the version bump commit" "commit it by hand" false 2>/dev/null || rc=$?
  assert_equal "$rc" 1
  assert_equal "$(grep -c "the version bump commit" <<< "${POST_DEPLOY_FAILED[0]:-}")" 1
}

# 0.7.2 exactly: the bump fails, and the milestone must still settle.
@test "a later step runs after an earlier one failed, and only the failure is recorded" {
  RAN=""
  settled()   { RAN="$RAN settled"; }
  announced() { RAN="$RAN announced"; }
  post_deploy "the version bump commit" "commit it by hand" false 2>/dev/null || true
  post_deploy "settling the milestone" "close it on GitHub" settled || true
  post_deploy "the release-check announcement" "list the labelled issues" announced || true
  assert_equal "$RAN" " settled announced"
  assert_equal "${#POST_DEPLOY_FAILED[@]}" 1
}

@test "several failures are all kept, in the order they happened" {
  post_deploy "first"  "do the first thing"  false 2>/dev/null || true
  post_deploy "second" "do the second thing" false 2>/dev/null || true
  assert_equal "${#POST_DEPLOY_FAILED[@]}" 2
  assert_equal "$(printf '%s\n' "${POST_DEPLOY_FAILED[@]}" | sed 's/ (exit.*//' | paste -sd,)" "first,second"
}

# Readable without the surrounding output.
@test "the warning names the step and says production is live" {
  run post_deploy "settling the milestone" "close it on GitHub" false
  assert_output --partial 'settling the milestone'
  assert_output --partial 'production is live'
}

# `git commit` returning 1 and returning 128 are different problems, and only
# one of them is the pre-commit hook.
@test "the exit code is in the message and in the recorded entry" {
  post_deploy "a step" "fix it" bash -c 'exit 42' 2>"$ERR" || true
  assert_equal "$(grep -c 'exit 42' "$ERR")" 1
  assert_equal "$(grep -c 'exit 42' <<< "${POST_DEPLOY_FAILED[0]:-}")" 1
}

# "Needs doing by hand" is not something anybody can act on at the end of a deploy.
@test "the remedy is printed, and kept for the closing summary" {
  post_deploy "settling the milestone" "close it on GitHub" false 2>"$ERR" || true
  assert_equal "$(grep -c 'close it on GitHub' "$ERR")" 1
  assert_equal "$(grep -c 'close it on GitHub' <<< "${POST_DEPLOY_FAILED[0]:-}")" 1
}

@test "arguments reach the command intact" {
  SEEN=""
  record() { SEEN="$*"; }
  post_deploy "with arguments" "none" record 1 "two words" 3 || true
  assert_equal "$SEEN" "1 two words 3"
}
