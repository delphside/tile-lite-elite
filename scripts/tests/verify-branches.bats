#!/usr/bin/env bats

# verify.sh notices a merged branch whose remote has been deleted.
#
# The check existed and did not work, and the reason is the thing under test.
# `check_branches` reads `[gone]` from `upstream:track`, which git only sets once
# the stale remote-tracking ref has been pruned, and `check_pushed`, the only
# thing that fetches, fetched without `--prune`. So the ref survived, `track`
# stayed empty, and the check passed for a reason with nothing to do with
# branches. `103-tab-icon` was merged on 2026-09-05, GitHub deleted its remote on
# merge, and verify.sh reported "no merged branches left behind" for a day.
#
# A real git fixture rather than a stub, because the defect is entirely in what
# git reports about refs. A stubbed git would have been written against the
# same wrong assumption as the code.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  ROOT="$BATS_TEST_DIRNAME/../.."
  D="$BATS_TEST_TMPDIR"
  # A bare origin, a clone, a branch merged into main, and its remote deleted,
  # which is what GitHub does when a pull request merges.
  git init -q --bare "$D/origin.git"
  git clone -q "$D/origin.git" "$D/work" 2>/dev/null
  cd "$D/work"
  git config user.email t@example.com; git config user.name test
  git commit -q --allow-empty -m base; git branch -M main; git push -q -u origin main
  git checkout -q -b feature; git commit -q --allow-empty -m work; git push -q -u origin feature
  git checkout -q main; git merge -q --ff-only feature; git push -q origin main
  # Deleted in the bare repository directly, not with `git push --delete` from
  # here. That is the whole fixture: pushing a delete prunes this clone's
  # remote-tracking ref as a side effect, so `track` would read `[gone]` with no
  # fetch at all and the test would pass against the broken code. The first
  # version of this test got that wrong and said so on its first run.
  git -C "$D/origin.git" branch -D feature -q
}

track() { git for-each-ref --format='%(upstream:track)' refs/heads/feature; }

# The check's own condition: gone, and merged into main.
merged_and_gone() {
  local found="" ref t
  while read -r ref t; do
    [[ "$t" == "[gone]" ]] || continue
    git merge-base --is-ancestor "$ref" origin/main 2>/dev/null || continue
    found="$found $ref"
  done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)
  echo "$found"
}

@test "before pruning, and after a plain fetch, track is empty rather than [gone]" {
  assert_equal "$(track)" ""
  # What the old code did.
  git fetch -q origin
  assert_equal "$(track)" ""
}

@test "a pruning fetch marks it [gone], and the check names the merged branch" {
  # What verify.sh does now.
  git fetch -q --prune origin
  assert_equal "$(track)" "[gone]"
  assert_equal "$(merged_and_gone)" " feature"
}

# A scratch branch mid-thought is not litter, and naming it trains the reader
# to ignore the line.
@test "an unmerged branch with a live remote is left alone" {
  git checkout -q -b scratch; git commit -q --allow-empty -m wip; git push -q -u origin scratch
  git checkout -q main; git fetch -q --prune origin
  assert_equal "$(merged_and_gone)" " feature"
}

# The guard that would catch the regression.
@test "verify.sh fetches with --prune" {
  run grep -c 'git fetch -q --prune origin' "$ROOT/scripts/verify.sh"
  assert_output 1
}
