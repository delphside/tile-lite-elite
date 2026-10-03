#!/usr/bin/env bats

# .githooks/commit-msg. git invokes hooks directly, so a hook that aborts on an
# unset variable fails the commit with no explanation at all; the hook runs as
# its own process here, under its own `set -euo pipefail`.
#
# The hook is a convenience rather than a gate: it lives in a working copy and
# `--no-verify` skips it, which is why check-commit-stamp.sh still runs in CI.
# What it must not do is refuse a correct commit, because a hook that cries wolf
# gets disabled and then protects nothing. So the accept cases matter as much as
# the refusals.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  HOOK="$BATS_TEST_DIRNAME/../../.githooks/commit-msg"
  # A scratch repository carrying the two files the hook reads versions from.
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  mkdir -p "$R/crates/api/src" "$R/scripts"
  printf '[workspace.package]\nversion = "0.5.2"\n' > "$R/Cargo.toml"
  printf 'pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 10 };\n' > "$R/crates/api/src/lib.rs"
  cp "$BATS_TEST_DIRNAME/../read-api-version.sh" "$R/scripts/"
}

hook() {   # <message> [CLAUDECODE value]: run the hook on it, in the scratch repository
  printf '%s\n' "$1" > "$R/msg"
  if [[ -n "${2:-}" ]]; then
    run bash -c 'cd "$1" && CLAUDECODE=1 "$2" "$1/msg"' _ "$R" "$HOOK"
  else
    run bash -c 'cd "$1" && env -u CLAUDECODE "$2" "$1/msg"' _ "$R" "$HOOK"
  fi
}

# The mistake that prompted the hook: a stamp with the colon missing. CI caught
# it six minutes later, by which time the commit was no longer the tip and
# fixing it needed a rebase rather than an amend.
@test "it refuses the missing colon" {
  hook "app 0.5.2 api 2.10 no colon here"; assert_failure
}

@test "it refuses a stamp with no subject after it" {
  hook "app 0.5.2 api 2.10:"; assert_failure
}

@test "it refuses no stamp at all" {
  hook "docs: a bare scope prefix"; assert_failure
}

@test "it refuses versions the tree disagrees with" {
  hook "app 0.5.1 api 2.10: wrong app"; assert_failure
  hook "app 0.5.2 api 2.9: wrong api"; assert_failure
}

@test "it accepts a correct stamp" {
  hook "app 0.5.2 api 2.10: a real subject"; assert_success
}

@test "it accepts the subjects git writes: merge, revert, fixup, squash" {
  hook "Merge branch 'x' into y"; assert_success
  hook 'Revert "app 0.5.2 api 2.10: x"'; assert_success
  hook "fixup! app 0.5.2 api 2.10: x"; assert_success
  hook "squash! app 0.5.2 api 2.10: x"; assert_success
}

# The hook adds `Co-Authored-By: Claude` when CLAUDECODE is set, so the absence
# of one means the owner typed the commit himself. Adding it when it should not
# be there would make his own commits claim Claude wrote them, which is the
# failure this convention exists to avoid.
@test "no trailer when the owner commits" {
  hook "app 0.5.2 api 2.10: x"
  run grep -c '^Co-Authored-By: Claude' "$R/msg"
  assert_output 0
}

@test "a trailer when Claude commits" {
  hook "app 0.5.2 api 2.10: x" yes
  run grep -c '^Co-Authored-By: Claude' "$R/msg"
  assert_output 1
}

# The hook cannot know the model, and the history distinguishes Opus 5, Sonnet 5
# and Opus 4.8.
@test "a hand-written model-specific trailer is not duplicated or replaced" {
  hook $'app 0.5.2 api 2.10: x\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>' yes
  run grep -c '^Co-Authored-By:' "$R/msg"
  assert_output 1
  run grep -q 'Claude Opus 5' "$R/msg"
  assert_success
}

@test "a refused commit gains no trailer" {
  hook "no stamp here" yes
  run grep -c '^Co-Authored-By:' "$R/msg"
  assert_output 0
}
