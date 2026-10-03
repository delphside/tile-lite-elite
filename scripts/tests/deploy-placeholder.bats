#!/usr/bin/env bats

# deploy.sh's placeholder-milestone check: the mirror image of the "nothing
# mentions this" half of the milestone gate (#265 R2, from #260).
#
# The half that matters is the quiet one: an issue sitting in `patch` that this
# release does not touch is next release's work, in the right place, and saying
# so would train somebody to ignore the gate.
#
# Written because the requirement it implements reached a merged delivery
# without being built, and the gate is only reachable by deploying, which is
# how #150 survived in the code beside it. Hence a function, and hence this.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../deploy.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  # `gh issue list --milestone X` answers from a per-milestone variable, so a
  # test can put an issue in one placeholder and not the others.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--milestone patch"*)      printf '%s\n' "${PATCH_ISSUES:-}" ;;
  *"--milestone minor"*)      printf '%s\n' "${MINOR_ISSUES:-}" ;;
  *"--milestone major"*)      printf '%s\n' "${MAJOR_ISSUES:-}" ;;
  *"--milestone no-release"*) printf '%s\n' "${NO_RELEASE_ISSUES:-}" ;;
  *)                          : ;;
esac
STUB
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  # Stubbed at the function, not at git. This suite tests which issues
  # placeholder_shipping names, given which ones the release mentions; how a
  # mention is recognised is the model's (board/refs.py, #421) and tested
  # there. A stub mimicking `git rev-list --grep` went stale twice.
  commits_mentioning() {
    local n
    for n in ${MENTIONED:-}; do [[ "$2" == "$n" ]] && { echo 1; return; }; done
    echo 0
  }
}

@test "an untouched issue in patch is silent" {
  export PATCH_ISSUES=$'260\tA change can ship under a placeholder' MENTIONED=""
  run placeholder_shipping abc123
  assert_output ""
}

@test "an issue this release mentions is named, with the placeholder it is in" {
  export PATCH_ISSUES=$'260\tA change can ship under a placeholder' MENTIONED=260
  run placeholder_shipping abc123
  assert_output --partial "#260"
  assert_output --partial "FILED UNDER patch"
}

@test "minor and major are checked too" {
  export MINOR_ISSUES=$'301\tSomething in minor' MAJOR_ISSUES=$'302\tSomething in major' MENTIONED="301 302"
  run placeholder_shipping abc123
  assert_output --partial "FILED UNDER minor"
  assert_output --partial "FILED UNDER major"
}

@test "no placeholder issues at all is silent" {
  export MENTIONED=260
  run placeholder_shipping abc123
  assert_output ""
}

# The gate must name the one that is shipping, not the whole milestone.
@test "only the mentioned one among several is named" {
  export PATCH_ISSUES=$'260\tShipping now\n261\tNot this time\n262\tAlso not' MENTIONED=260
  run placeholder_shipping abc123
  assert_equal "$(grep -c '#' <<< "$output")" 1
  assert_output --partial "#260"
}

# 5 open and 60 closed on 2026-09-01, against none in the other three. Both
# projects shipping in 0.7.1 were filed under it, the gate said nothing, and the
# milestone was corrected by hand on the morning of the deploy. #281.
@test "an issue shipping from no-release is named, with the placeholder" {
  export NO_RELEASE_ISSUES=$'303\tA project shipping while filed under no-release' MENTIONED=303
  run placeholder_shipping abc123
  assert_output --partial "#303"
  assert_output --partial "FILED UNDER no-release"
}

# The quiet half: filed under no-release and not shipping, which is most of them.
@test "an untouched issue in no-release is silent" {
  export NO_RELEASE_ISSUES=$'303\tA project nobody is shipping' MENTIONED=""
  run placeholder_shipping abc123
  assert_output ""
}
