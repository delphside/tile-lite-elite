#!/usr/bin/env bats

# check-commit-stamp.sh. This gate has failed open once already: an unguarded
# parse returned nothing, `|| true` swallowed it, and the check passed every
# commit for weeks while appearing to work. A gate that has stopped checking
# looks exactly like a gate everything passed, so most cases are refusals.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  CHECK="$BATS_TEST_DIRNAME/../check-commit-stamp.sh"
  # A scratch repository carrying the two files the stamp is checked against.
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name Test
  mkdir -p "$R/crates/api/src"
}

commit_at() {   # <app> <api> <subject>: commit with the tree claiming those versions
  printf '[workspace.package]\nversion = "%s"\n' "$1" > "$R/Cargo.toml"
  printf 'pub const API_VERSION: ApiVersion = ApiVersion { major: %s, minor: %s };\n' \
    "${2%%.*}" "${2##*.}" > "$R/crates/api/src/lib.rs"
  # A nonce, so two commits claiming the same versions still differ.
  date +%s%N >> "$R/nonce"
  git -C "$R" add -A
  git -C "$R" commit -q -m "$3"
}

stamp_check() { run bash -c 'cd "$1" && shift && "$@"' _ "$R" "$CHECK" "$@"; }

@test "a stamp true of its own tree passes" {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: a subject"
  stamp_check
  assert_success
}

@test "a missing stamp is refused" {
  commit_at 0.4.25 2.10 "no stamp at all"
  stamp_check
  assert_equal "$status" 1
}

@test "a bare scope prefix is refused" {
  commit_at 0.4.25 2.10 "rules: a bare scope prefix"
  stamp_check
  assert_equal "$status" 1
}

@test "an app version the tree disagrees with is refused" {
  commit_at 0.4.25 2.10 "app 0.4.24 api 2.10: claims the wrong app version"
  stamp_check
  assert_equal "$status" 1
}

@test "an api version the tree disagrees with is refused" {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.9: claims the wrong api version"
  stamp_check
  assert_equal "$status" 1
}

@test "a stamp with no subject after it is refused" {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10:"
  stamp_check
  assert_equal "$status" 1
}

# The failure that started all this: API_VERSION wrapped onto four lines when
# the minor reached two digits, and the old parser returned nothing, which is
# indistinguishable from "no api crate here", so the check skipped itself. This
# pins the wrapped shape through this caller, not only in read-api-version's
# own tests.
@test "a wrapped API_VERSION is still read, not skipped" {
  printf '[workspace.package]\nversion = "0.4.25"\n' > "$R/Cargo.toml"
  printf 'pub const API_VERSION: ApiVersion = ApiVersion {\n    major: 2,\n    minor: 10,\n};\n' \
    > "$R/crates/api/src/lib.rs"
  git -C "$R" add -A
  git -C "$R" commit -q -m "app 0.4.25 api 2.9: wrong api, with the constant wrapped"
  stamp_check
  assert_equal "$status" 1
}

@test "a range checks every commit in it, not just the tip" {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: first"
  base="$(git -C "$R" rev-parse HEAD)"
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: second"
  commit_at 0.4.25 2.10 "bad subject on the third"
  stamp_check "$base..HEAD"
  assert_equal "$status" 1
}

merge_side() {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: on main"
  git -C "$R" checkout -q -b side
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: on the side"
  git -C "$R" checkout -q -
  base="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" merge -q --no-ff side -m "Merge: a generated subject with no stamp"
}

@test "a merge commit is skipped, its subject describing no change" {
  merge_side
  stamp_check "$base..HEAD"
  assert_success
}

# The path CI takes when github.event.before is all zeros, which is what a newly
# pushed branch looks like. It failed: the no-argument path used
# `git rev-parse HEAD` without --no-merges, so a branch whose tip was a merge
# failed CI for a reason that was not real, while the range form passed.
@test "a merge at HEAD is skipped with no range given too" {
  merge_side
  stamp_check
  assert_success
}

@test "an empty range passes rather than erroring" {
  commit_at 0.4.25 2.10 "app 0.4.25 api 2.10: only commit"
  stamp_check HEAD..HEAD
  assert_success
}
