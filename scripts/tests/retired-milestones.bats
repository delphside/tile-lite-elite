#!/usr/bin/env bats

# The milestone names `pre-approved`, `no-release`, `patch`, `minor` and `major`
# are retired: a milestone is a semver or a date (programme CLAUDE.md, owner,
# 2026-10-26; #545 R10). The issue forms and issue-mentions.sh's example must not
# name one as a milestone, or a reader takes it as still current.
#
# `pre-approved` and `no-release` are named nowhere in these files. `patch`,
# `minor` and `major` are ordinary English elsewhere, so they count only on a
# line that also speaks of a milestone. `deploy.sh`'s placeholder gate names them
# on purpose and is not in the list (retired in 0.10.3).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  ROOT="$BATS_TEST_DIRNAME/../.."
}

# The lines of FILE... that name a retired milestone, as `file:line:text`.
names_retired() {
  grep -nHiE '(^|[^A-Za-z])(pre-approved|no-release)([^A-Za-z]|$)' "$@" || true
  grep -nHiE 'milestone.*\b(patch|minor|major)\b|\b(patch|minor|major)\b.*milestone' "$@" || true
}

@test "the issue forms and issue-mentions.sh's example name no retired milestone" {
  run names_retired "$ROOT"/.github/ISSUE_TEMPLATE/*.yml "$ROOT/scripts/deliver/issue-mentions.sh"
  assert_output ''
}

# Without these the check could pass because it can never match.
@test "the check finds a retired name where one is planted" {
  local f="$BATS_TEST_TMPDIR/form.yml"
  for plant in 'milestone: patch' 'projects sitting in no-release' 'the pre-approved milestone' 'a minor milestone' 'Milestone: Major'; do
    printf 'a line\n%s\n' "$plant" > "$f"
    run names_retired "$f"
    assert_output --partial "$plant"
  done
}

@test "the check leaves ordinary English alone" {
  local f="$BATS_TEST_TMPDIR/form.yml"
  printf 'a minor fix\nthe patch applies\nmilestone: 0.10.2\nmilestone: 2026.11.16-1\nmajor version\n' > "$f"
  run names_retired "$f"
  assert_output ''
}
