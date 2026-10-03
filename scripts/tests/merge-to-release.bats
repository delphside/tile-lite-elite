#!/usr/bin/env bats

# merge-to-release.sh (#344 R4, R5). gh and ci-status.sh are both stubbed,
# because the whole point of the script is which questions it asks and what it
# does with the answers. The merge itself is GitHub's and is not under test;
# that it is not reached when a check fails is the thing that matters.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../merge-to-release.sh"
  export STUB_DIR="$BATS_TEST_TMPDIR"
  BIN="$STUB_DIR/bin"; mkdir -p "$BIN"
  # One stub for every gh call, dispatching on the subcommand. MERGED records the
  # whole merge call: the strategy was unasserted until 2026-09-09, and
  # `--rebase` rewrites the commits, so the tested SHA is not the landed SHA and
  # the commit stamp breaks after the merge, where nothing can see it.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")  cat "$STUB_DIR/pr.json" ;;
  "pr merge") printf '%s\n' "$*" > "$STUB_DIR/MERGED" ;;
  "api "*)    cat "$STUB_DIR/baseref" ;;
  "run list") cat "$STUB_DIR/runs" ;;
  *)          echo "unexpected gh: $*" >&2; exit 9 ;;
esac
STUB
  # Exits 0 unless the spec it is given is named in CI_FAIL, and records what it
  # was asked, so the second question, the one a blunt implementation forgets,
  # is seen to be asked at all.
  cat > "$BIN/ci-status.sh" <<'STUB'
#!/usr/bin/env bash
spec=""
while (( $# )); do [[ "$1" == "--run" ]] && { shift; spec="$1"; }; shift; done
echo "$spec" >> "$STUB_DIR/ASKED"
for bad in ${CI_FAIL:-}; do [[ "$spec" == "$bad" ]] && exit 1; done
exit 0
STUB
  # The board correction: asserted to be triggered, not what it does. SYNC_FAIL
  # makes it fail, which is the case that must not fail the merge.
  cat > "$BIN/sync-pr-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "ran" > "$STUB_DIR/SYNCED"
[ -n "${SYNC_FAIL:-}" ] && exit 1
exit 0
STUB
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH" CI_STATUS="$BIN/ci-status.sh" SYNC_PR_STATE="$BIN/sync-pr-state.sh"
  : > "$STUB_DIR/ASKED"
  pr '"baseRefName":"release/0.7.3","state":"OPEN","isDraft":false'
  printf 'bbbbbbbbbbbb\n' > "$STUB_DIR/baseref"
  printf 'pull_request\t301-x\npush\trelease/0.7.3\n' > "$STUB_DIR/runs"
}

pr() { printf '{"number":9,"headRefName":"301-x","headRefOid":"aaaaaaaaaaaa",%s}' "$1" > "$STUB_DIR/pr.json"; }
merge() { run "$SCRIPT" "$@"; }
merged() { [ -f "$STUB_DIR/MERGED" ]; }

@test "a green pull request onto a green tip merges, having asked about both" {
  merge 9
  assert_success
  assert merged
  run grep -qx pull_request "$STUB_DIR/ASKED"
  assert_success
  run grep -qx push:release/0.7.3 "$STUB_DIR/ASKED"
  assert_success
}

@test "a red pull request is refused, and nothing is merged" {
  export CI_FAIL=pull_request
  merge 9
  assert_equal "$status" 1
  refute merged
}

# The case a blunt implementation misses.
@test "a green pull request onto a red tip is refused, and nothing is merged" {
  export CI_FAIL=push:release/0.7.3
  merge 9
  assert_equal "$status" 1
  refute merged
}

# R5: absence is never a silent pass.
@test "a missing pull-request run refuses, out loud, and nothing is merged" {
  printf 'push\trelease/0.7.3\n' > "$STUB_DIR/runs"
  merge 9
  assert_equal "$status" 1
  assert_output --regexp 'No .* run for'
  refute merged
}

@test "a missing run for the tip refuses, and nothing is merged" {
  printf 'pull_request\t301-x\n' > "$STUB_DIR/runs"
  merge 9
  assert_equal "$status" 1
  refute merged
}

@test "--allow-missing-run proceeds, and still says the run was absent" {
  printf 'push\trelease/0.7.3\n' > "$STUB_DIR/runs"
  merge 9 --allow-missing-run
  assert_success
  assert_output --regexp 'No .* run for'
}

@test "a push run on main is not the tip's run" {
  printf 'pull_request\t301-x\npush\tmain\n' > "$STUB_DIR/runs"
  merge 9
  assert_equal "$status" 1
}

# Refused for that reason, before CI is asked: without a run for main the
# script would refuse later anyway, which let a missing check pass until
# 2026-09-27.
@test "a pull request onto main is refused as not a release branch, before CI is asked" {
  pr '"baseRefName":"main","state":"OPEN","isDraft":false'
  merge 9
  assert_equal "$status" 1
  assert_output --partial "which is not a release branch"
  assert_equal "$(grep -c . "$STUB_DIR/ASKED")" 0
  refute merged
}

@test "a draft is refused" {
  pr '"baseRefName":"release/0.7.3","state":"OPEN","isDraft":true'
  merge 9
  assert_equal "$status" 1
}

@test "an already-merged pull request is refused" {
  pr '"baseRefName":"release/0.7.3","state":"MERGED","isDraft":false'
  merge 9
  assert_equal "$status" 1
}

@test "--check-only passes the checks, and merges and corrects nothing" {
  merge 9 --check-only
  assert_success
  refute merged
  assert [ ! -f "$STUB_DIR/SYNCED" ]
  # Either order.
  merge --check-only 9
  refute merged
  assert [ ! -f "$STUB_DIR/SYNCED" ]
}

@test "a non-numeric argument is a usage error" {
  merge notanumber
  assert_equal "$status" 2
}

# #338 was tested as 21d40b2 and landed as fa25f7a with a different tree, so
# its run proved a commit that never existed on the release branch, and the
# rewritten commit then failed check-commit-stamp.sh. A merge preserves each
# commit's tree, so stamps survive.
@test "the merge is a merge, never a rebase, and the branch is still deleted" {
  merge 9
  run cat "$STUB_DIR/MERGED"
  assert_output --partial -- --merge
  refute_output --partial -- --rebase
  assert_output --partial -- --delete-branch
}

# PR State goes stale between a merge and the next verify.sh; #401 sat in
# Approved long enough on 2026-09-22 for the owner to notice first.
@test "a merge corrects the board" {
  merge 9
  assert [ -f "$STUB_DIR/SYNCED" ]
}

# The merge cannot be undone by a board field, so a failure here prints and the
# script still reports success.
@test "a failed correction still reports the merge, and says how to rerun it" {
  export SYNC_FAIL=1
  merge 9
  assert_success
  assert_output --partial 'run scripts/sync-pr-state.sh'
}
