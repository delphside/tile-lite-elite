#!/usr/bin/env bats

# .claude/turn-check.sh's comment filter, against a fixture rather than GitHub.
#
# This is the part that has failed twice, both times silently, because the real
# pipeline sends stderr to /dev/null and an empty result is indistinguishable
# from a quiet day:
#
#   1. it excluded Claude's comments by testing the body for "Typed by Claude",
#      a convention from when both accounts were one. Nothing had written that
#      marker for weeks, so every comment Claude wrote was reported as Steve's.
#   2. the fix used `--jq --arg me "$ME"`, and `gh api` has no --arg. It failed
#      with "accepts 1 arg(s), received 4" and reported nothing at all.
#
# The filter is fetched with `--print-filter` so the test exercises what the
# script actually runs, rather than a copy that can drift from it.

setup_file() {
  command -v jq >/dev/null || skip "jq is not installed"
  export FILTER
  FILTER="$("$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" --print-filter)"
  # The bot login is whatever the filter was built with, so the fixture is
  # written against the filter rather than against a hardcoded name.
  export ME
  ME="$(printf '%s' "$FILTER" | sed -n 's/.*select(.user.login != "\([^"]*\)").*/\1/p' | head -1)"
}

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  run jq -r "$FILTER" <<< "$(fixture)"
  assert_success
}

fixture() {
  cat <<JSON
[ {"user":{"login":"$ME"},"issue_url":"https://api.github.com/repos/o/r/issues/1",
   "updated_at":"2026-09-04T09:00:00Z","body":"a note Claude wrote"},
  {"user":{"login":"SteveStyle"},"issue_url":"https://api.github.com/repos/o/r/issues/2",
   "updated_at":"2026-09-04T09:01:00Z","body":"not approved, see the checklist"},
  {"user":{"login":"SteveStyle"},"issue_url":"https://api.github.com/repos/o/r/issues/3",
   "updated_at":"2026-09-04T09:02:00Z","body":"[deploy.sh] deployed 0.7.1 to production"},
  {"user":{"login":"$ME"},"issue_url":"https://api.github.com/repos/o/r/issues/4",
   "updated_at":"2026-09-04T09:03:00Z","body":"Typed by Claude — the old marker, which nothing writes now"} ]
JSON
}

@test "--print-filter prints a filter, naming an account to exclude" {
  assert [ -n "$FILTER" ]
  assert [ -n "$ME" ]
}

@test "only the owner's own comment survives, and it is the one from issue 2" {
  assert_equal "$(grep -c '^#' <<< "$output")" 1
  assert_line --regexp '^#2 '
}

@test "Claude's, deploy.sh's and the old marker's comments are excluded" {
  refute_line --regexp '^#1 '
  refute_line --regexp '^#3 '
  refute_line --regexp '^#4 '
}

# The regression that started this: if the filter matched on body text instead
# of author, comment 4 would be the only one excluded and comment 1 would show.
@test "a Claude comment without the marker is still excluded" {
  refute_output --partial 'a note Claude wrote'
}
