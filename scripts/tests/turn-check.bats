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
  load fixtures
  use_fake_profiles
  export FILTER ME
  FILTER="$("$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" --print-filter)"
  # The bot login is whatever the filter was built with, so the fixture is
  # written against the filter rather than against a hardcoded name.
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
  {"user":{"login":"fake-owner"},"issue_url":"https://api.github.com/repos/o/r/issues/2",
   "updated_at":"2026-09-04T09:01:00Z","body":"not approved, see the checklist"},
  {"user":{"login":"fake-owner"},"issue_url":"https://api.github.com/repos/o/r/issues/3",
   "updated_at":"2026-09-04T09:02:00Z","body":"[ship.sh] deployed 0.7.1 to production"},
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

@test "Claude's, the deploy's and the old marker's comments are excluded" {
  refute_line --regexp '^#1 '
  refute_line --regexp '^#3 '
  refute_line --regexp '^#4 '
}

# The regression that started this: if the filter matched on body text instead
# of author, comment 4 would be the only one excluded and comment 1 would show.
@test "a Claude comment without the marker is still excluded" {
  refute_output --partial 'a note Claude wrote'
}

# The announcement a deploy makes is the technical profile's `release.deploy_marker`
# (#485), so another profile's marker is the one excluded.
@test "the deploy's marker is the profile's" {
  other="$(PROGRAMME_PROFILE="$FAKES/programme-other.toml" "$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" --print-filter)"
  run jq -r "$other" <<< "$(fixture)"
  assert_success
  assert_line --regexp '^#3 '
  refute_output --partial '[out]'
  grep -q 'startswith("\[out\]")' <<< "$other"
}

# The marker is spliced into the filter as a JSON string literal, so a quote or a
# backslash in it is a character of the marker and not part of the filter.
@test "a marker with a quote or a backslash is a value, not part of the filter" {
  sed 's/^deploy_marker = .*/deploy_marker = "\\"] \\\\ ("/' "$FAKES/programme.toml" > "$BATS_TEST_TMPDIR/odd.toml"
  grep -q 'deploy_marker = ' "$BATS_TEST_TMPDIR/odd.toml"
  odd="$(PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/odd.toml" "$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" --print-filter)"
  grep -qF 'startswith("\"] \\ (")' <<< "$odd"
  run jq -r "$odd" <<< "$(fixture)"
  assert_success
  assert_line --regexp '^#2 '
}

# The dev machine has no jq (#329): the comment filter must run inside `gh api
# --jq`, which carries its own. A fake gh applies --jq with the test's jq, found
# before the PATH is narrowed; the script itself must not call a jq.
@test "the comment check works on a PATH with no jq" {
  REALJQ="$(command -v jq)"
  APP="$BATS_TEST_TMPDIR/app"
  mkdir -p "$APP/.claude" "$APP/scripts" "$BATS_TEST_TMPDIR/bin"
  git init -q "$APP"
  cp "$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" "$APP/.claude/"
  cp -r "$BATS_TEST_DIRNAME/../programme" "$APP/scripts/programme"
  find "$APP/scripts/programme" -name __pycache__ -prune -exec rm -rf {} +
  fixture > "$BATS_TEST_TMPDIR/comments.json"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<GH
#!/bin/bash
args=("\$@")
filter=""
for ((i = 0; i < \${#args[@]}; i++)); do [[ "\${args[i]}" == --jq ]] && filter="\${args[i+1]}"; done
case "\$1 \$2" in
  "api user") echo "$ME" ;;
  "api repos/{owner}/{repo}/issues/comments?"*) "$REALJQ" -r "\$filter" "$BATS_TEST_TMPDIR/comments.json" ;;
esac
exit 0
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  for tool in bash env python3 date stat cat sed head timeout git grep cut md5sum mktemp touch rm dirname tr wc sort uniq printf; do
    p="$(command -v "$tool" || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$BATS_TEST_TMPDIR/bin/$tool"
  done
  run env PATH="$BATS_TEST_TMPDIR/bin" TURN_CHECK_SWEEP_SECS=999999 "$APP/.claude/turn-check.sh" </dev/null
  assert_line --regexp '^#2 '
  refute_output --partial '#1 '
}

@test "a profile that cannot be read ends the check, saying so, and does not fail the turn" {
  run env PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/nowhere.toml" "$BATS_TEST_DIRNAME/../../.claude/turn-check.sh" --print-filter
  assert_success
  assert_output --partial "$BATS_TEST_TMPDIR/nowhere.toml"
}
