#!/usr/bin/env bats

# .githooks/post-merge: a merged project branch moves its work package on. The
# hook must fire for `git merge <N-branch>` on main and for nothing else, since
# the same hook runs on every pull. Tested in scratch repositories, with the
# board call replaced by a stub. What the board call decides is
# board/tests/test_merge.py.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  HOOK="$BATS_TEST_DIRNAME/../../.githooks/post-merge"
  STUB="$BATS_TEST_TMPDIR/stub.sh"
  CALLS="$BATS_TEST_TMPDIR/calls"
  printf '#!/usr/bin/env bash\necho "$1" >> "%s"\n' "$CALLS" > "$STUB"
  chmod +x "$STUB"
}

repo() {  # <name> <branch>: main, the branch one commit ahead, and the hook
  local dir="$BATS_TEST_TMPDIR/$1"
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" checkout -q -b "$2"
  git -C "$dir" commit -q --allow-empty -m work
  git -C "$dir" checkout -q main
  cp "$HOOK" "$dir/.git/hooks/post-merge"
  D="$dir"
}

called() { cat "$CALLS" 2>/dev/null || true; }

@test "a numbered branch fast-forwarded into main runs it" {
  repo a 415-x
  POST_MERGE_CMD="$STUB" git -C "$D" merge -q --ff-only 415-x
  assert_equal "$(called)" 415-x
}

@test "so does its remote-tracking ref, named without origin/" {
  repo b 415-x
  git -C "$D" update-ref refs/remotes/origin/415-x 415-x
  POST_MERGE_CMD="$STUB" git -C "$D" merge -q --ff-only origin/415-x
  assert_equal "$(called)" 415-x
}

@test "a branch with no issue number does not" {
  repo c tidy-up
  POST_MERGE_CMD="$STUB" git -C "$D" merge -q --ff-only tidy-up
  assert_equal "$(called)" ""
}

@test "a merge on a project branch does not" {
  repo d 415-x
  git -C "$D" checkout -q -b 416-y main
  POST_MERGE_CMD="$STUB" git -C "$D" merge -q --ff-only 415-x
  assert_equal "$(called)" ""
}

@test "a pull into main does not, though it is a merge too" {
  repo e 415-x
  git clone -q "$D" "$BATS_TEST_TMPDIR/clone"
  # The origin's own merge has the hook too, so it gets the stub: the old suite
  # left it unset, and the hook called the real board command for #415.
  POST_MERGE_CMD="$STUB" git -C "$D" merge -q --ff-only 415-x
  rm -f "$CALLS"
  cp "$HOOK" "$BATS_TEST_TMPDIR/clone/.git/hooks/post-merge"
  POST_MERGE_CMD="$STUB" git -C "$BATS_TEST_TMPDIR/clone" pull -q --ff-only
  assert_equal "$(called)" ""
}

@test "a failing board call does not fail the merge" {
  repo f 415-x
  POST_MERGE_CMD=/bin/false run git -C "$D" merge -q --ff-only 415-x
  assert_success
}
