#!/usr/bin/env bats

# issue-mentions.sh's commits_mentioning. The defect it replaced was invisible
# without `pipefail`: the same line reported correctly under `set -eu` and
# wrongly under `set -euo pipefail`, which is how it survived into a production
# deploy.
#
# The fixtures are real commits in this repository's history, because the
# failure depends on volume. A fixture with one matching commit passes against
# the broken code, which is exactly why #194 survived to fire on a real
# release. CI checks out with fetch-depth: 0 for this reason.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  export REPO_DIR="$BATS_TEST_DIRNAME/../.."
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../issue-mentions.sh"
}

# The exact case that fired on a production release: #174 from d2adc63. Fifty
# commits mention it; thirty-five carry its trailer, and the other fifteen are
# documentation commits citing it in prose while belonging to something else
# (D40, #320). The old `git log … | grep -q .` reported failure ten times out
# of ten at this size, not intermittently.
@test "many commits: counted, not lost to SIGPIPE" {
  assert_equal "$(commits_mentioning d2adc63 174)" 35
}

# With one matching commit `git log` finishes before `grep -q` bails, so the old
# pipeline reported correctly. A suite built only from cases like this is why
# #194 survived to fire on a real release.
@test "one commit: still counted" {
  assert_equal "$(commits_mentioning HEAD 153)" 1
}

# The case the gate exists for. A check that can only say yes is not a gate.
@test "no commits: reports none" {
  assert_equal "$(commits_mentioning HEAD 99999)" 0
}

# An unknown ref must not abort a deploy that has passed every other gate. Not
# knowing is reported as "nothing mentions it", which warns rather than
# closing an issue silently.
@test "an unknown ref: 0, and no abort" {
  run commits_mentioning no-such-ref-exists 174
  assert_success
  assert_output 0
}

# Measured from d2adc63, `#17` without a boundary matches 68 commits and `#17\b`
# matches 1. Without it the gate would call a stale issue built on the strength
# of commits belonging to a different one.
@test "word boundary: #17 is not #170-something" {
  assert_equal "$(commits_mentioning d2adc63 17)" 1
}

# The defect replaced is a race in principle even where it is deterministic in
# practice, so a single green run would not tell "fixed" from "got lucky".
@test "ten consecutive runs agree" {
  for _ in $(seq 1 10); do
    assert_equal "$(commits_mentioning d2adc63 174)" 35
  done
}

# D40: the trailer is the claim, a mention is not. The 0.7.2 release was
# refused by this: b231721 carries `Refs #299` and names #224 and #241 in its
# prose, and counting any `#N` read that as both of them shipping.
@test "a prose mention does not count, on the commit that refused 0.7.2" {
  assert_equal "$(commits_mentioning 9293893 224)" 0
  assert_equal "$(commits_mentioning 9293893 241)" 0
}

# Scoped to that one commit with a range: `rev-list <ref>` walks all history.
@test "the trailer on that same commit counts, and its prose mention still does not" {
  assert_equal "$(commits_mentioning 'b231721^..b231721' 299)" 1
  assert_equal "$(commits_mentioning 'b231721^..b231721' 224)" 0
}

# #103 has four commits mentioning it and three carrying its trailer. The
# fourth is db1b7f6, whose trailer is `Refs #299`.
@test "mentions and trailers are told apart (#103)" {
  assert_equal "$(commits_mentioning 9293893 103)" 3
}

# CLAUDE.md reserves Closes for a change that never leaves the repository, but
# it is still a claim of ownership.
@test "the history really does use Closes, so that arm is exercised" {
  run bash -c "git -C '$REPO_DIR' log --format=%B -400 | grep -cE '^Closes #[0-9]+'"
  assert [ "$output" -gt 0 ]
}

# The shape this function exists to replace still fails, so this test would
# notice if somebody reintroduced it believing it worked.
@test "the old pipeline still fails, so this is not cargo cult" {
  run bash -c "set -euo pipefail; git -C '$REPO_DIR' log --oneline d2adc63 --grep='#174\\b' | grep -q ."
  assert_equal "$status" 141
}
