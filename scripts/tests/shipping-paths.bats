#!/usr/bin/env bats

# shipping-paths.sh: the functions the bash callers source, against real
# commits. The rule itself is board/shipping.py's and is tested there
# (board/tests/test_shipping.py); this pins the adapters deploy.sh, verify.sh
# and CI call, including the range form a pull request needs (#348).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
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
  source "$BATS_TEST_DIRNAME/../application/deliver/shipping-paths.sh"
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
