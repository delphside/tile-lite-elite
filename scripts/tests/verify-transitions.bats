#!/usr/bin/env bats

# verify.sh's transition check. The behaviour it pins is the contract, not the
# wording: this check never fails. board-check.py reports and does not refuse,
# since a field is changed in a browser and nothing can stand in front of that,
# so surfacing it through verify.sh must not put the deploy path's trusted exit
# status at the mercy of bookkeeping.
#
# Exit 2 is the case worth having: it is "no gh or jq", not "nothing is wrong".
# Reporting it as a pass is the shape that let 0.5.0 through the release gate,
# absence read as success, so it is tested apart from a clean run.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  VERIFY="$BATS_TEST_DIRNAME/../verify.sh"
}

# Runs verify.sh's check_transitions alone against a stubbed
# scripts/board-check.py: 0 clean, 2 could not run, anything else findings.
#   $1  the exit status the stub returns
#   $2  what the stub prints
#   $3  "timeout" to stub `timeout` as having killed it (exit 124), which
#       reaches that branch without waiting 60 seconds
transitions() {
  local status="$1" printed="$2" mode="${3:-}" work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work/scripts" "$work/bin"
  printf '%s' "$printed" > "$work/out"
  printf '#!/usr/bin/env bash\ncat "%s/out"\nexit %s\n' "$work" "$status" > "$work/scripts/board-check.py"
  chmod +x "$work/scripts/board-check.py"
  if [[ "$mode" == timeout ]]; then
    printf '#!/usr/bin/env bash\nexit 124\n' > "$work/bin/timeout"
    chmod +x "$work/bin/timeout"
  fi
  run bash -c '
    cd "$1"
    PATH="$1/bin:$PATH"
    source <(sed -n "/^check_transitions()/,/^}/p" "$2")
    # The real three-argument signature: the detail lines are what a reader
    # acts on, and a stub that drops them tests something other than the code.
    pass() { printf "PASS %s\n%s\n" "$2" "${3:-}"; }
    fail() { printf "FAIL %s\n%s\n" "$2" "${3:-}"; }
    note() { printf "NOTE %s\n%s\n" "$2" "${3:-}"; }
    declare -A LABEL
    check_transitions' _ "$work" "$VERIFY"
}

first_word() { awk '{print $1; exit}' <<< "$output"; }

@test "findings report as a note, and the issue is named in the detail" {
  transitions 1 'ISSUE COMPLETENESS  R4 - each issue against its type and step
#309 Requirement at On Hold  The machine account token expires
    !!  something named under dependencies

Totals  160 met  1 missing  8 not checked
'
  assert_equal "$(first_word)" NOTE
  assert_output --partial '#309'
}

# The milestone check reports like the other release-scoped sections,
# `  !! #N ...`. A detail filter that took only `#N` lines turned the summary
# red and printed nothing under it.
@test "a section finding, which is not a #N line, reaches the detail" {
  transitions 1 'MILESTONE  0.8.2 carries only built work
  !! #268 WorkPackage #71 WP A: Core Game Lifecycle  no commit mentions this
  !! unbuilt: #268
'
  assert_output --partial 'no commit mentions this'
}

@test "a clean run passes" {
  transitions 0 'ISSUE COMPLETENESS  R4 - each issue against its type and step

  every open issue has done the work its field claims
'
  assert_equal "$(first_word)" PASS
}

@test "exit 2 is could not run, never a pass" {
  transitions 2 "check-transitions: no 'gh' on PATH"
  assert_equal "$(first_word)" NOTE
  assert_output --partial 'could not run'
}

@test "a timeout is a note, and says it timed out" {
  transitions 1 irrelevant timeout
  assert_equal "$(first_word)" NOTE
  assert_output --partial 'timed out'
}

# The contract, asserted directly.
@test "no exit status produces a FAIL" {
  local st
  for st in 0 1 2 3; do
    transitions "$st" 'anything at all'
    refute_line --regexp '^FAIL'
  done
}
