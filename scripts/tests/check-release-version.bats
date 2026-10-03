#!/usr/bin/env bats

# check-release-version.sh. It runs during a release, and the cases that matter
# are the ones where it must not fail: a release should never be blocked because
# a tag is missing or GitHub is unreachable.
#
# Isolation is a PATH of symlinks to exactly the tools the script uses, and
# nothing else. An earlier version set `PATH=/usr/bin:/bin` and passed here while
# failing in CI, because gh lives in ~/.local/bin on this machine and in
# /usr/bin on a GitHub runner. Naming the tools is the only way to be sure of
# what is absent.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  CHECK="$BATS_TEST_DIRNAME/../check-release-version.sh"
  D="$BATS_TEST_TMPDIR"
  BIN="$D/bin"; mkdir -p "$BIN"
  # Everything the script reaches for, including what its shebang and heredoc
  # need. A missing one shows up as exit 127, not as a wrong answer.
  local tool
  for tool in env bash cat git sed sort tail jq; do
    ln -s "$(command -v "$tool")" "$BIN/$tool"
  done
  PATH="$BIN" git init -q "$D/repo"
}

# No gh at all, so the only inputs are the arguments.
isolated() { run bash -c 'cd "$1" && PATH="$2" "${@:3}"' _ "$D/repo" "$BIN" "$CHECK" "$@"; }

# With a gh stub, so the API path is driven. Every case above it runs with no gh,
# which meant the query deciding whether a milestone carries functional change
# had never been exercised: rewritten from REST to GraphQL on 2026-08-26, and
# the suite stayed green because it could not see the path.
#
# The stub runs the real --jq filter. Returning pre-filtered output would
# exercise the branching and not the query, and a filter selecting nothing looks
# exactly like a milestone with nothing functional in it: `any(. == "a", "b")`
# is jq's one-argument form with a truthy generator, and matched everything.
with_gh() {   # <answer> <version> <previous>
  printf '%s' "$1" > "$D/answer.json"
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
filter=""; prev=""
for a in "$@"; do [[ "$prev" == "--jq" ]] && filter="$a"; prev="$a"; done
case "$*" in
  *"repo view"*) printf '%s\n' "delphside/tile-lite-elite" ;;
  *graphql*)
    # The query is recorded, so a case can assert what was asked and not only
    # how the answer was parsed.
    printf '%s\n' "$*" >> "$QUERY_LOG"
    if [[ -n "$filter" ]]; then jq -r "$filter" < "$ANSWER_FILE"; else cat "$ANSWER_FILE"; fi ;;
  *) : ;;
esac
STUB
  chmod +x "$BIN/gh"
  export ANSWER_FILE="$D/answer.json" QUERY_LOG="$D/queries"
  isolated "${@:2}"
}

FUNCTIONAL='{"data":{"search":{"nodes":[{"number":123,"title":"a change a user could notice",
  "issueFieldValues":{"nodes":[{"value":"functional","field":{"name":"Type of change"}}]}}]}}}'
EMPTY='{"data":{"search":{"nodes":[]}}}'
TOOLING='{"data":{"search":{"nodes":[{"number":124,"title":"a script change",
  "issueFieldValues":{"nodes":[{"value":"tooling","field":{"name":"Type of change"}}]}}]}}}'

# Each of these is a release that must go ahead.
@test "no previous release passes, and says why" {
  isolated 0.4.26
  assert_success
  assert_output --partial "no previous release"
}

@test "an unparseable previous release passes, and says why" {
  isolated 0.4.26 not-a-version
  assert_success
  assert_output --partial "not an X.Y.Z version"
}

@test "no gh available passes, and says why" {
  isolated 0.4.26 0.4.25
  assert_success
  assert_output --partial "gh not available"
}

# A minor release is allowed to contain fixes, so it short-circuits before it
# would ever look at the milestone, which is why it passes with no gh.
@test "a minor or major release passes, without needing gh" {
  isolated 0.5.0 0.4.25
  assert_success
  assert_output --partial "minor or major release"
  isolated 1.0.0 0.4.25
  assert_success
}

# Bad arguments are the caller's fault, not a skip.
@test "no version, a non-version and a two-part version are usage errors" {
  run "$CHECK"
  assert_equal "$status" 2
  run "$CHECK" banana
  assert_equal "$status" 2
  run "$CHECK" 0.4
  assert_equal "$status" 2
}

# The whole point of the check, and the one behaviour no test drove until
# 2026-08-26.
@test "a patch carrying functional change is refused, and names the issue" {
  with_gh "$FUNCTIONAL" 0.4.26 0.4.25
  assert_equal "$status" 1
  assert_output --partial "#123"
}

@test "a patch carrying nothing functional, or only tooling, passes" {
  with_gh "$EMPTY" 0.4.26 0.4.25
  assert_success
  with_gh "$TOOLING" 0.4.26 0.4.25
  assert_success
  assert_output --partial "a patch release is right"
}

# is:issue is load-bearing and its absence made this gate blind. Measured
# against the live repository on 2026-09-09: `repo:… milestone:"0.7.3"` returns
# 0 issues where `repo:… is:issue milestone:"0.7.3"` returns 5, so the check
# reported nothing functional for every release it ever ran on.
@test "the query asks for is:issue, and still filters by the milestone" {
  with_gh "$EMPTY" 0.4.26 0.4.25
  run grep -q -- is:issue "$QUERY_LOG"
  assert_success
  run grep -q -- milestone: "$QUERY_LOG"
  assert_success
}
