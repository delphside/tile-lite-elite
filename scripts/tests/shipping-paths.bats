#!/usr/bin/env bats

# shipping-paths.sh: the functions the bash callers source, against real
# commits. The rule itself is board/shipping.py's and is tested there
# (board/tests/test_shipping.py); this pins the adapters deploy.sh, verify.sh
# and CI call, including the range form a pull request needs (#348).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  load fixtures
  use_fake_profiles
  export REPO_DIR="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" config user.email t@t
  git -C "$REPO_DIR" config user.name t
  mkdir -p "$REPO_DIR/docs" "$REPO_DIR/crates/ui/src" "$REPO_DIR/scripts"
  echo one > "$REPO_DIR/docs/a.md"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m base
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../deliver/shipping-paths.sh"
}

commit_file() {   # <path> <message>
  echo "$RANDOM" > "$REPO_DIR/$1"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "$2"
}

# The #345 case #348 was raised from.
@test "a pull request touching only docs across several commits does not reach the image" {
  commit_file docs/b.md "docs only, commit 1"
  commit_file docs/c.md "docs only, commit 2"
  run touches_image_range "$BASE_SHA" HEAD
  assert_equal "$status" 1
}

# The per-commit form would have to be run once per commit and OR'd; the range
# form answers it in one diff.
@test "a pull request reaches the image if any of its commits does" {
  commit_file docs/b.md "docs only"
  commit_file crates/ui/src/x.rs "the image changes"
  run touches_image_range "$BASE_SHA" HEAD
  assert_success
}

@test "a pull request touching only scripts/ does not reach the image" {
  commit_file scripts/build.sh "tooling only"
  run touches_image_range "$BASE_SHA" HEAD
  assert_equal "$status" 1
}

# The version bump after a release reaches the image by path and ships
# nothing, so deploy.sh's emergency check must not count it; a crate change
# beside it must.
@test "a version bump alone does not ship, though it touches the image by path" {
  printf '[workspace.package]\nversion = "0.9.0"\n' > "$REPO_DIR/Cargo.toml"
  git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -q -m "release 0.9.0"
  sed -i 's/0.9.0/0.9.1/' "$REPO_DIR/Cargo.toml"
  git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -q -m "bump to 0.9.1"
  run ships HEAD
  assert_equal "$status" 1
  run touches_image HEAD
  assert_success
}

@test "a crate change ships" {
  commit_file crates/ui/src/lib.rs "a crate change"
  run ships HEAD
  assert_success
}

# What ships is the technical profile's list (#485), so the same commits answer
# differently under another profile.
@test "the answer is the profile's: under another one docs/ ships and spec/ does not" {
  commit_file docs/b.md "docs"
  export PROGRAMME_PROFILE="$FAKES/programme-other.toml"
  run touches_image_range "$BASE_SHA" HEAD
  assert_success
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  mkdir -p "$REPO_DIR/spec"
  commit_file spec/s.md "spec"
  run touches_image_range "$BASE_SHA" HEAD
  assert_equal "$status" 1
}

# A profile that cannot be read is neither yes nor no (#485 review): the loader
# exits 70 and the functions stop their caller with the message, where reading
# it as "does not reach the image" would let a gate pass.
@test "an unreadable profile stops touches_image, touches_image_range and ships" {
  commit_file crates/ui/src/x.rs "the image changes"
  printf 'application = "widget"\n' > "$BATS_TEST_TMPDIR/bare.toml"
  export PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/bare.toml"
  for call in "touches_image HEAD" "touches_image_range $BASE_SHA HEAD" "ships HEAD" "require_shipping_profile"; do
    run $call
    assert_equal "$status" 70
    assert_output --partial "bare.toml"
  done
}

@test "an unreadable profile ends a script that asks inside an if, as deploy.sh and verify.sh do" {
  printf 'application = "widget"\n' > "$BATS_TEST_TMPDIR/bare.toml"
  export PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/bare.toml"
  run bash -c 'source "$1"; if ships HEAD; then echo ships; else echo does-not-ship; fi; echo carried-on' _ "$BATS_TEST_DIRNAME/../deliver/shipping-paths.sh"
  assert_equal "$status" 70
  refute_output --partial "does-not-ship"
  refute_output --partial "carried-on"
}

# The `programme/` submodule not being checked out is Python's status 2, and
# every caller reads anything but 0 as "no": the stamp and touches-image CI jobs
# did this, and e2e was skipped on pull requests that reach the image.
@test "a missing board-shipping.py stops every function, and an if does not read it as no" {
  commit_file crates/ui/src/x.rs "the image changes"
  _SHIPPING_CMD="$BATS_TEST_TMPDIR/no-such/board-shipping.py"
  for call in "touches_image HEAD" "touches_image_range $BASE_SHA HEAD" "ships HEAD" "require_shipping_profile"; do
    run $call
    assert_equal "$status" 70
    assert_output --partial "git submodule update --init"
  done
  run bash -c 'source "$1"; _SHIPPING_CMD="$2"; if ships HEAD; then echo ships; else echo does-not-ship; fi; echo carried-on' \
    _ "$BATS_TEST_DIRNAME/../deliver/shipping-paths.sh" "$BATS_TEST_TMPDIR/no-such/board-shipping.py"
  assert_equal "$status" 70
  refute_output --partial "does-not-ship"
}

@test "a command that exits with a status other than 0 or 1 is an error, not a no" {
  commit_file crates/ui/src/x.rs "the image changes"
  printf '#!/usr/bin/env python3\nimport sys\nprint("it broke", file=sys.stderr)\nsys.exit(2)\n' > "$BATS_TEST_TMPDIR/odd.py"
  _SHIPPING_CMD="$BATS_TEST_TMPDIR/odd.py"
  run touches_image HEAD
  assert_equal "$status" 70
  assert_output --partial "status 2"
  assert_output --partial "it broke"
}

# A malformed regular expression in the profile makes the model raise; Python calls
# an uncaught exception status 1, which every caller reads as "no". The commands now
# exit 70 on a crash (`profile.run`) and `_ask_shipping` stops on it.
@test "a malformed ships regex stops touches_image, touches_image_range and ships, rather than answering no" {
  commit_file crates/ui/src/x.rs "the image changes"
  sed "s|^non_shipping = \[|non_shipping = [\n  'docs/(',|" "$FAKES/programme.toml" > "$BATS_TEST_TMPDIR/broken.toml"
  export PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/broken.toml"
  for call in "touches_image HEAD" "touches_image_range $BASE_SHA HEAD" "ships HEAD"; do
    run $call
    assert_equal "$status" 70
    assert_output --partial "Traceback"
  done
  run bash -c 'source "$1"; if ships HEAD; then echo ships; else echo does-not-ship; fi; echo carried-on' _ "$BATS_TEST_DIRNAME/../deliver/shipping-paths.sh"
  assert_equal "$status" 70
  refute_output --partial "does-not-ship"
}

# `check` has no "no", so a 1 is a failure before the command could answer, such
# as an import or syntax error, which `profile.run` cannot catch.
@test "require_shipping_profile stops when check exits 1" {
  printf '#!/usr/bin/env python3\nimport sys\nprint("it failed to load", file=sys.stderr)\nsys.exit(1)\n' > "$BATS_TEST_TMPDIR/one.py"
  _SHIPPING_CMD="$BATS_TEST_TMPDIR/one.py"
  run require_shipping_profile
  assert_equal "$status" 70
  assert_output --partial "could not be checked"
}
