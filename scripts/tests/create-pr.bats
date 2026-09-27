#!/usr/bin/env bats

# create-pr.sh. #410's lesson: creation had no choke point, so the board sat
# unset until something else happened to run sync-pr-state.sh.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../create-pr.sh"
  export STUB_DIR="$BATS_TEST_TMPDIR"
  # gh stubbed for the one call this script makes, `pr create`. It records the
  # whole argument list, so the reviewer default and passthrough are checkable.
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr create" ]]; then
  printf '%s\n' "$*" > "$STUB_DIR/CREATED"
  [[ -n "${GH_CREATE_FAIL:-}" ]] && exit 1
  exit 0
fi
echo "unexpected gh: $*" >&2; exit 9
STUB
  cat > "$STUB_DIR/sync-pr-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "ran" > "$STUB_DIR/SYNCED"
[[ -n "${SYNC_FAIL:-}" ]] && exit 1
exit 0
STUB
  chmod +x "$STUB_DIR/gh" "$STUB_DIR/sync-pr-state.sh"
  export PATH="$STUB_DIR:$PATH"
  export SYNC_PR_STATE="$STUB_DIR/sync-pr-state.sh"
}

created() { cat "$STUB_DIR/CREATED" 2>/dev/null || true; }

@test "the reviewer defaults to SteveStyle, and the board is corrected after" {
  run "$SCRIPT" --base main --head x --title t --body-file /dev/null
  assert_success
  assert_equal "$(grep -c -- '--reviewer SteveStyle' <<< "$(created)")" 1
  assert [ -f "$STUB_DIR/SYNCED" ]
}

@test "an explicit --reviewer overrides the default, which is not also passed" {
  run "$SCRIPT" --base main --head x --title t --body-file /dev/null --reviewer other
  assert_equal "$(grep -c -- '--reviewer other' <<< "$(created)")" 1
  assert_equal "$(grep -c -- '--reviewer SteveStyle' <<< "$(created)")" 0
}

@test "a missing --base is a usage error, and nothing is created" {
  run "$SCRIPT" --head x --title t --body-file /dev/null
  assert_equal "$status" 2
  assert_equal "$(created)" ""
}

@test "a failed gh pr create is not swallowed, and the board is not touched" {
  export GH_CREATE_FAIL=1
  run "$SCRIPT" --base main --head x --title t --body-file /dev/null
  assert_equal "$status" 1
  assert [ ! -f "$STUB_DIR/SYNCED" ]
}

@test "a failed sync still reports the pull request created, and says how to rerun it" {
  export SYNC_FAIL=1
  run "$SCRIPT" --base main --head x --title t --body-file /dev/null
  refute_output --partial 'FAILED'
  refute_output --partial 'error'
  assert_output --partial 'run scripts/sync-pr-state.sh'
}
