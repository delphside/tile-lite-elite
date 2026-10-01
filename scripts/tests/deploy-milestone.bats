#!/usr/bin/env bats

# deploy.sh's milestone settlement: what a release closes, and what an
# emergency deliberately does not.
#
# This code was unreachable by any test until it became a function: it runs
# after a deploy has finished, so exercising it meant deploying. That is how
# #150 survived: the normal-release path sat inside the emergency branch, so a
# normal release fell off the end of the `if` in silence, and 0.6.0's eleven
# issues and its milestone were closed by hand afterwards.
#
# gh is stubbed and records what it was asked to do, so each case asserts the
# calls rather than the printed text. settle_milestone calls nothing else.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../application/deliver/deploy.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export GH_CALLS="$BATS_TEST_TMPDIR/calls"; : > "$GH_CALLS"
  # Answers the shapes deploy.sh asks for, with what the real gh would print
  # after its own --jq, and records every call.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$*" in
  *"milestones?state=open"*)   echo "${MILESTONE_NUMBER:-7}" ;;
  *"milestones?state=all"*)    printf '%s\n' ${EXISTING_MILESTONES:-} ;;
  *"issue list"*)              printf '%s\n' ${MILESTONE_ISSUES:-} ;;
  # Keyed on the number in the path, so one milestone can hold a parent and a
  # work package and the assertion can tell which was skipped.
  *"/sub_issues"*)             n="$*"; n="${n#*/issues/}"; n="${n%%/*}"
                               case " ${PARENT_ISSUES:-} " in *" $n "*) echo 1 ;; *) echo 0 ;; esac ;;
  *"--json issueType"*)        echo "${ISSUE_TYPE-Project}" ;;
  *"--json issueFieldValues"*) echo "${ISSUE_PHASE-Deployment}" ;;
  *"--json id"*)               echo "I_node_${RANDOM}" ;;
  # Matched on the shape, not just the name: setIssueFieldValue takes
  # `issueFields:[…]`, a list, where createIssueFieldValue takes a singular
  # `issueField:{…}`. A stub matching the name alone accepted a malformed
  # mutation the real API rejects.
  *"setIssueFieldValue(input:{issueId:"*"issueFields:[{fieldId:"*)
                               exit "${PHASE_SET_EXIT:-0}" ;;
  *"setIssueFieldValue"*)      echo "stub: malformed setIssueFieldValue: $*" >&2; exit 1 ;;
  *)                           : ;;
esac
STUB
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  # What the deploy has already established by the time this runs.
  IS_RELEASE=1; EMERGENCY=""; DEPLOY_ENV="production"
  DEPLOYED_VERSION="0.7.1"; NEXT_VERSION="0.7.2"
  DEPLOY_TAG="prod-0.7.1"; TARGET_SHA="abc1234"
  export MILESTONE_ISSUES="" EXISTING_MILESTONES="" MILESTONE_NUMBER=7 PARENT_ISSUES=""
}

calls() { grep -c -- "$1" "$GH_CALLS" || true; }
settle() { run settle_milestone; }

@test "a release advances each project to Post-deployment, closes none, and closes the milestone" {
  export MILESTONE_ISSUES="201 202"
  settle
  assert_equal "$(calls 'issue close')" 0
  assert_equal "$(calls setIssueFieldValue)" 2
  assert_equal "$(calls 'issue comment')" 2
  assert_equal "$(calls milestones/7)" 1
  assert_equal "$(calls title=0.7.2)" 1
  assert_output --partial "Settling milestone 0.7.1"
}

@test "#150: a normal release does not silently do nothing" {
  export MILESTONE_ISSUES=201
  settle
  assert_equal "$(calls setIssueFieldValue)" 1
}

@test "an emergency settles nothing, and says why" {
  EMERGENCY="site down, rolled forward"
  export MILESTONE_ISSUES="201 202"
  settle
  assert_equal "$(calls 'issue close')" 0
  assert_equal "$(calls milestones/7)" 0
  assert_equal "$(calls title=0.7.2)" 0
  assert_output --partial "has not been through the normal process"
}

@test "a rehearsal deploy closes nothing, and says it has not reached users" {
  IS_RELEASE=0; DEPLOY_ENV=rehearsal
  export MILESTONE_ISSUES=201
  settle
  assert_equal "$(calls 'issue close')" 0
  assert_output --partial "a rehearsal deploy has not reached users"
}

# A project whose last delivery has not shipped is not in this milestone
# (docs/5.1 §1.1), so the guarantee needed is that nothing outside the list is
# touched. #195: a project was closed by the first of its three deliveries.
@test "it settles exactly the milestone's issues, no more" {
  export MILESTONE_ISSUES=201
  settle
  assert_equal "$(calls setIssueFieldValue)" 1
  assert_equal "$(calls 'issue comment 201')" 1
}

@test "an existing next milestone is not created again" {
  export EXISTING_MILESTONES="0.7.1 0.7.2"
  settle
  assert_equal "$(calls title=0.7.2)" 0
}

# D51: the parent owns the requirements and the design, and its packages carry
# the deliveries. #71 carries 1.0.0 while #269-#272 carry the work, so a 1.0.0
# release would have told a parent that shipped nothing it was released.
@test "a parent's milestone is a target: it is skipped, and says why, and the milestone still closes" {
  export MILESTONE_ISSUES=71 PARENT_ISSUES=71
  settle
  assert_equal "$(calls setIssueFieldValue)" 0
  assert_equal "$(calls 'issue comment')" 0
  assert_equal "$(calls 'issue close')" 0
  assert_output --partial "a parent, whose milestone is a target"
  assert_equal "$(calls milestones/7)" 1
}

# The package is the thing that shipped. Counts alone would pass if both were skipped.
@test "a parent and its package in one milestone: only the package settles" {
  export MILESTONE_ISSUES="71 269" PARENT_ISSUES=71
  settle
  assert_equal "$(calls setIssueFieldValue)" 1
  assert_equal "$(calls 'issue comment 269')" 1
  assert_equal "$(calls 'issue comment 71')" 0
}

@test "DEPLOY_SKIP_BUMP: no bump, no next milestone" {
  export DEPLOY_SKIP_BUMP=1
  settle
  assert_equal "$(calls title=0.7.2)" 0
}

# #263: closing here took the moment the post-deployment review was meant to
# happen, and the Post-deployment column cannot hold a closed project.
@test "a shipped project is left open for its review, at Post-deployment" {
  export MILESTONE_ISSUES=201
  settle
  assert_equal "$(calls 'issue close')" 0
  assert_equal "$(calls setIssueFieldValue)" 1
  assert_output --partial "left open for its review"
}

@test "shipping from the wrong phase is said out loud, and still advanced" {
  export MILESTONE_ISSUES=201 ISSUE_PHASE=Development
  settle
  assert_output --partial "was at 'Development', not 'Deployment'"
  assert_equal "$(calls setIssueFieldValue)" 1
}

# Milestones belong to projects, so this should not arise, and the gate calls
# it out. Closing is what used to happen, so nothing new is invented for it.
@test "a non-project in a milestone is closed, and given no phase" {
  export MILESTONE_ISSUES=201 ISSUE_TYPE=Requirement
  settle
  assert_equal "$(calls 'issue close')" 1
  assert_equal "$(calls setIssueFieldValue)" 0
}

# D51: a delivery is a sub-project and carries its own post-deployment checks,
# so it waits for its review like any project.
@test "a work package is advanced, and not closed" {
  export MILESTONE_ISSUES=202 ISSUE_TYPE=Project
  settle
  assert_equal "$(calls setIssueFieldValue)" 1
  assert_equal "$(calls 'issue close')" 0
}

# Falling back would restore the defect at exactly the moment nobody is watching.
@test "a phase that cannot be set does not fall back to closing" {
  export MILESTONE_ISSUES=201 PHASE_SET_EXIT=1
  settle
  assert_equal "$(calls 'issue close')" 0
  assert_output --partial "could not set the phase"
}
