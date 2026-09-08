#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's milestone settlement — what a release closes, and what an
# emergency deliberately does not.
#
# This code was unreachable by any test until it became a function: it runs
# after a deploy has finished, so exercising it meant deploying. That is how
# #150 survived — the normal-release path sat *inside* the emergency branch, so
# a normal release fell off the end of the `if` in silence, and 0.6.0's eleven
# issues and its milestone were closed by hand afterwards. Nothing noticed for a
# release and a half.
#
# `gh` is stubbed and records what it was asked to do, so each case asserts the
# calls rather than the printed text.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

# shellcheck source=/dev/null
DEPLOY_SH_FUNCTIONS_ONLY=1 source "$HERE/deploy.sh"

setup() {
  DIR="$(mktemp -d)"; BIN="$DIR/bin"; mkdir -p "$BIN"
  GH_CALLS="$DIR/calls"; : > "$GH_CALLS"; export GH_CALLS
  # Answers the three shapes deploy.sh asks for, and records every call.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
# The stub answers with what the real `gh` would print *after* its own --jq,
# because it cannot run jq itself.
case "$*" in
  *"milestones?state=open"*)   echo "${MILESTONE_NUMBER:-7}" ;;
  *"milestones?state=all"*)    printf '%s\n' ${EXISTING_MILESTONES:-} ;;
  *"issue list"*)              printf '%s\n' ${MILESTONE_ISSUES:-} ;;
  *"--json issueType"*)        echo "${ISSUE_TYPE-Project}" ;;
  *"--json issueFieldValues"*) echo "${ISSUE_PHASE-Deployment}" ;;
  *"--json id"*)               echo "I_node_${RANDOM}" ;;
  # Matched on the *shape*, not just the name. `setIssueFieldValue` takes
  # `issueFields:[…]` — a list — where its sibling `createIssueFieldValue` takes
  # a singular `issueField:{…}`. The first version of this stub matched the name
  # alone and happily accepted a malformed mutation the real API rejects.
  *"setIssueFieldValue(input:{issueId:"*"issueFields:[{fieldId:"*)
                               exit "${PHASE_SET_EXIT:-0}" ;;
  *"setIssueFieldValue"*)      echo "stub: malformed setIssueFieldValue: $*" >&2; exit 1 ;;
  *)                           : ;;
esac
STUB
  chmod +x "$BIN/gh"; PATH="$BIN:$PATH"
  # What the deploy has already established by the time this runs.
  IS_RELEASE=1; EMERGENCY=""; DEPLOY_ENV="production"
  DEPLOYED_VERSION="0.7.1"; NEXT_VERSION="0.7.2"
  DEPLOY_TAG="prod-0.7.1"; TARGET_SHA="abc1234"
  MILESTONE_ISSUES=""; EXISTING_MILESTONES=""; MILESTONE_NUMBER=7
  export MILESTONE_ISSUES EXISTING_MILESTONES MILESTONE_NUMBER
  # Reset per case, or a scenario's issue type leaks into the next one — which
  # it did while these were being written, turning a project into a requirement
  # and closing it.
  unset DEPLOY_SKIP_BUMP ISSUE_TYPE ISSUE_PHASE PHASE_SET_EXIT || true
}
teardown() { rm -rf "$DIR"; }

check() {  # name, expected, actual
  if [[ "$2" == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; echo "     wanted: $2"; echo "     got:    $3"; failures=$((failures + 1)); fi
}
calls_matching() { grep -c -- "$1" "$GH_CALLS" 2>/dev/null || true; }

# --- a normal release settles everything -------------------------------------
setup
MILESTONE_ISSUES="201 202"; export MILESTONE_ISSUES
out="$(settle_milestone)"
check "a release advances each project, and closes none" "0" "$(calls_matching 'issue close')"
check "each is moved to Post-deployment"                 "2" "$(calls_matching 'setIssueFieldValue')"
check "and still says it was released"                   "2" "$(calls_matching 'issue comment')"
check "and closes the milestone itself"                  "1" "$(calls_matching 'milestones/7')"
check "and opens the next one"                           "1" "$(calls_matching 'title=0.7.2')"
check "and says so"                                      "yes" \
  "$(case "$out" in *"Settling milestone 0.7.1"*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# --- #150: the case that fell off the end of the if --------------------------
setup
MILESTONE_ISSUES="201"; EMERGENCY=""; export MILESTONE_ISSUES
out="$(settle_milestone)"
check "#150: a normal release does not silently do nothing" "1" "$(calls_matching 'setIssueFieldValue')"
teardown

# --- an emergency deliberately settles nothing -------------------------------
setup
EMERGENCY="site down, rolled forward"
MILESTONE_ISSUES="201 202"; export MILESTONE_ISSUES
out="$(settle_milestone)"
check "an emergency closes nothing"          "0" "$(calls_matching 'issue close')"
check "and does not close the milestone"     "0" "$(calls_matching 'milestones/7')"
check "and does not open the next"           "0" "$(calls_matching 'title=0.7.2')"
check "and says why, rather than nothing"    "yes" \
  "$(case "$out" in *"has not been through the normal process"*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# --- a rehearsal or preview deploy has not reached users ----------------------
setup
IS_RELEASE=0; DEPLOY_ENV="rehearsal"
MILESTONE_ISSUES="201"; export MILESTONE_ISSUES
out="$(settle_milestone)"
check "a non-release closes nothing" "0" "$(calls_matching 'issue close')"
check "and says which environment"   "yes" \
  "$(case "$out" in *"a rehearsal deploy has not reached users"*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# --- it closes what the milestone says, and nothing wider --------------------
# A project whose last delivery has not shipped is not in this milestone
# (docs/3.6 §1.1), so the guarantee needed is that nothing outside the list is
# touched. #195: a project was closed by the first of its three deliveries.
setup
MILESTONE_ISSUES="201"; export MILESTONE_ISSUES
settle_milestone > /dev/null
check "settles exactly the milestone's issues, no more" "1" "$(calls_matching 'setIssueFieldValue')"
check "and it is the one listed"                        "1" "$(calls_matching 'issue comment 201')"
teardown

# --- the next milestone is not opened twice ----------------------------------
setup
MILESTONE_ISSUES=""; EXISTING_MILESTONES="0.7.1 0.7.2"; export MILESTONE_ISSUES EXISTING_MILESTONES
settle_milestone > /dev/null
check "an existing next milestone is not created again" "0" "$(calls_matching 'title=0.7.2')"
teardown

# --- DEPLOY_SKIP_BUMP means the version did not move -------------------------
setup
MILESTONE_ISSUES=""; export MILESTONE_ISSUES
DEPLOY_SKIP_BUMP=1 settle_milestone > /dev/null
check "no bump, no next milestone" "0" "$(calls_matching 'title=0.7.2')"
teardown

# --- #263: a project is left open for its review ------------------------------
# The defect this replaced: closing here took with it the one moment the
# post-deployment review was meant to happen, and the `Post-deployment` column
# cannot hold a closed project because the board filters `is:open`.
setup
MILESTONE_ISSUES="201"; export MILESTONE_ISSUES
out="$(settle_milestone 2>&1)"
check "a shipped project is not closed"        "0" "$(calls_matching 'issue close')"
check "it is moved to Post-deployment instead" "1" "$(calls_matching 'setIssueFieldValue')"
check "and says it is waiting for a review"    "yes" \
  "$(case "$out" in *"left open for its review"*) echo yes ;; *) echo no ;; esac)"
teardown

# --- a project that skipped phases is called out, not advanced silently -------
setup
MILESTONE_ISSUES="201"; ISSUE_PHASE="Development"; export MILESTONE_ISSUES ISSUE_PHASE
out="$(settle_milestone 2>&1)"
check "shipping from the wrong phase is said out loud" "yes" \
  "$(case "$out" in *"was at 'Development', not 'Deployment'"*) echo yes ;; *) echo no ;; esac)"
check "and it is still advanced"                       "1" "$(calls_matching 'setIssueFieldValue')"
teardown

# --- a non-project in a milestone is still closed -----------------------------
# Milestones belong to projects, so this should not arise — the gate calls it
# out. Closing is what used to happen, so nothing new is invented for it.
setup
MILESTONE_ISSUES="201"; ISSUE_TYPE="Requirement"; export MILESTONE_ISSUES ISSUE_TYPE
out="$(settle_milestone 2>&1)"
check "a non-project is closed"          "1" "$(calls_matching 'issue close')"
check "and is not given a phase"         "0" "$(calls_matching 'setIssueFieldValue')"
teardown

# --- a work package is advanced, like any project ----------------------------
# **This asserted the opposite until 2026-09-08.** A delivery had its own type,
# `Project Delivery`, and `settle_issue` closed anything not exactly `Project`
# on the reasoning that a delivery is one unit of work with no review to wait
# for.
#
# D51 inverted that premise: a delivery is a **sub-project**, and it carries its
# own post-deployment checks precisely because a check is answered per delivery.
# So there *is* a review to wait for, and it advances like any project. The type
# was deleted the same day, so the old case tested a value that cannot occur.
setup
MILESTONE_ISSUES="202"; ISSUE_TYPE="Project"
export MILESTONE_ISSUES ISSUE_TYPE
out="$(settle_milestone 2>&1)"
check "a work package is advanced"         "1" "$(calls_matching 'setIssueFieldValue')"
check "and is not closed"                  "0" "$(calls_matching 'issue close')"
teardown

# --- a phase that cannot be set does NOT fall back to closing -----------------
# Falling back would restore the defect at exactly the moment nobody is watching.
setup
MILESTONE_ISSUES="201"; PHASE_SET_EXIT=1; export MILESTONE_ISSUES PHASE_SET_EXIT
out="$(settle_milestone 2>&1)"
check "a failed phase change closes nothing" "0" "$(calls_matching 'issue close')"
check "and says the project stays open"      "yes" \
  "$(case "$out" in *"could not set the phase"*) echo yes ;; *) echo no ;; esac)"
teardown

if (( failures )); then echo "$failures test(s) failed" >&2; exit 1; fi
echo
echo "All deploy milestone tests passed."
