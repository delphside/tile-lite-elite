#!/usr/bin/env bash
set -euo pipefail
# check-transitions.sh — has an issue done the work its stage or phase claims?
#
# A field says where something has got to. Nothing says the steps behind it were
# taken, so a requirement can reach `Ready for Project` with no effort recorded
# and a project can sit at `Development` with no test approach.
#
# **It reports; it does not refuse.** A field is changed in a browser and nothing
# here can stand in front of that. What it can do is notice afterwards, which is
# the same shape as verify.sh.
#
# Owner, 2026-09-03: "whenever a requirement or project moves stage or phase
# there should be a check that the previous steps are completed."

command -v gh >/dev/null || { echo "check-transitions: no 'gh' on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "check-transitions: no 'jq' on PATH" >&2; exit 2; }

Q='{repository(owner:"delphside",name:"tile-lite-elite"){issues(first:100,states:OPEN){nodes{number title body issueType{name} issueFieldValues(first:12){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}'
ISSUES="$(gh api graphql -f query="$Q" 2>/dev/null)" || {
  echo "check-transitions: could not read the issues" >&2; exit 2; }

echo "==> Open issues, against what their stage or phase claims"

ROWS="$(printf '%s' "$ISSUES" | jq -r '
  .data.repository.issues.nodes[] | . as $i
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Stage")|.name][0] // "-") as $stage
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Phase")|.name][0] // "-") as $phase
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Workstream")|.name][0] // "-") as $ws
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Type of change")|.name][0] // "-") as $toc
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Priority")|.name][0] // "-") as $pri
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Effort")|.name][0] // "-") as $eff
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Decision State")|.name][0] // "-") as $dstate
  | [$i.number, ($i.issueType.name // ""), $stage, $phase, $ws, $toc, $pri, $eff, $dstate,
     (($i.body // "") | @base64),
     (($i.body // "") | gsub("[\n\r]"; " "))] | @tsv')"

FAILURES=0
report() { printf "  #%-5s %-24s %s\n" "$1" "$2" "$3"; FAILURES=$((FAILURES+1)); }

# --- reading a Decision's body ------------------------------------------------
#
# A Decision closes when there is an Agreed Decision and every action is done.
# Owner, 2026-09-05: *"close should check there is an Agreed Decision and the
# actions are checked. Actions should come out of the decision. As normal
# discussion in the comments, conclusions in the body."*
#
# So the body is the record, and both halves are readable from it — which is the
# whole reason this is an issue type rather than a row in a document. The
# glossary said "answered" in a table and nothing could tell whether it had been
# applied.
#
# Both read from a here-string rather than a pipe. `awk | grep -q` makes grep
# exit on its first match, awk take SIGPIPE, and the pipeline report 141 under
# `pipefail` — so the test inverts silently. That has cost this project a
# production deploy; see scripts/issue-mentions.sh.

# The text under an `Agreed Decision` heading, if any of it is not blank.
# GitHub writes `_No response_` for a form field left empty, which is exactly
# the case this is looking for, so it counts as blank.
decision_agreed() {
  local section
  section="$(awk '
    /^#+[[:space:]]*Agreed Decision[[:space:]]*$/ { inside = 1; next }
    /^#+[[:space:]]/                              { inside = 0 }
    inside                                        { print }' <<< "$1")"
  grep -qvE '^[[:space:]]*(_No response_)?[[:space:]]*$' <<< "$section"
}

# Unchecked items under `Open actions` — the same heading `scripts/actions.py`
# reads, so a decision's actions appear in the one place that reports what is
# waiting. Anything else is invisible there, which is how #311's queue came to
# sit in front of that tool unseen.
decision_open_actions() {
  awk '
    /^#+[[:space:]]*Open actions/                    { inside = 1; next }
    /^#+[[:space:]]/                                 { inside = 0 }
    inside && /^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]/ { n++ }
    END                                              { print n + 0 }' <<< "$1"
}

# **Absence must not read as a pass**, which is the defect this check found in
# itself on its first run. #317 carried two unchecked actions under an
# `Action Items` heading — the first template's wording — so the counter above
# saw none and the rule said *close it*. That is the shape that let 0.5.0 out
# and that the milestone gate hit again on 2026-09-05: a check with nothing to
# read reporting success.
#
# So a body with no readable heading is not judged; it is reported as
# unreadable, which is a different sentence and a different fix.
decision_has_actions_heading() {
  grep -qE '^#+[[:space:]]*Open actions' <<< "$1"
}

# Every field is emitted as "-" when empty, because tab is an IFS whitespace
# character: bash collapses a run of them, so a genuinely empty field would
# merge with the next and shift the body out of reach. That failure is silent —
# the check simply stops finding anything.
while IFS=$'\t' read -r num kind stage phase ws toc pri eff dstate b64 body; do
  [ -n "$num" ] || continue
  for v in stage phase ws toc pri eff dstate; do
    [ "${!v}" = "-" ] && printf -v "$v" '%s' ""
  done
  case "$kind" in
    Requirement)
      case "$stage" in
        "Scope, Options and Dependencies"|"On Hold"|"Ready for Project"|Candidate*)
          [ -n "$ws" ]  || report "$num" "$stage" "triage set no workstream"
          [ -n "$toc" ] || report "$num" "$stage" "triage set no type of change"
          [ -n "$pri" ] || report "$num" "$stage" "triage set no priority"
          ;;
      esac
      case "$stage" in
        "On Hold")
          printf '%s' "$body" | grep -qi "depend" || report "$num" "$stage" "on hold with nothing under dependencies"
          ;;
      esac
      case "$stage" in
        "Ready for Project"|Candidate*)
          [ -n "$eff" ] || report "$num" "$stage" "scoped but no effort recorded"
          ;;
      esac
      ;;
    Project|"Project Delivery")
      case "$phase" in
        "Design and Test Approach"|Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Requirements" || report "$num" "$phase" "no requirements heading"
          printf '%s' "$body" | grep -q "## Design"       || report "$num" "$phase" "no design heading"
          ;;
      esac
      case "$phase" in
        Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Test approach"       || report "$num" "$phase" "no test approach"
          printf '%s' "$body" | grep -q "Technical tests"        || report "$num" "$phase" "test approach has no Preview/Rehearsal lists"
          printf '%s' "$body" | grep -q "## Impacted artefacts"  || report "$num" "$phase" "no impacted artefacts"
          ;;
      esac
      case "$phase" in
        Deployment|Post-deployment|"Project Closedown")
          printf '%s' "$body" | grep -q "## Deliveries"        || report "$num" "$phase" "no deliveries"
          printf '%s' "$body" | grep -qi "post-deployment check" || report "$num" "$phase" "no post-deployment checks"
          ;;
      esac
      case "$phase" in
        "Project Closedown")
          printf '%s' "$body" | grep -qi "lessons learnt" || report "$num" "$phase" "closing down with no lessons learnt"
          ;;
      esac
      ;;
    Decision)
      # A Decision has no Stage and no Phase. `Decision State` names where it has
      # got to — Asked, Decided, Actioned — and the body says the same thing in
      # prose: an *Agreed Decision* heading, and ticked boxes under *Open
      # actions*. Two records of one fact, which is the arrangement that goes
      # stale, so what is checked here is that they still agree.
      #
      # The body is the authority and the field is the index. A board column is
      # dragged in a browser and the body is not; the reverse also happens. Only
      # one of them can be read by a person deciding what to do next, and it is
      # not the column.
      DBODY="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
      if ! decision_has_actions_heading "$DBODY"; then
        report "$num" "open" "no 'Open actions' heading — its actions are invisible to actions.py"
      elif decision_agreed "$DBODY" && [ "$(decision_open_actions "$DBODY")" = "0" ] \
           && [ "$dstate" != "Actioned" ]; then
        # Not "close it" any more. D44 split applied from read: when the work is
        # done the step is to mark it Actioned, and the closing is the owner's
        # once he has read the outcome.
        report "$num" "open" "settled and every action done — mark it Actioned"
      fi
      case "$dstate" in
        "")
          report "$num" "open" "no Decision State — every open decision has at least been asked" ;;
        Asked)
          decision_agreed "$DBODY" &&
            report "$num" "Asked" "an agreed decision is written, but it is still marked Asked" ;;
        "Feedback Provided")
          # D45. With Claude: the owner has commented and Claude has still to
          # respond and *write the decision down*. Documenting it is what ends
          # this state, so an Agreed Decision present here means the work is done
          # and the state has not caught up.
          decision_agreed "$DBODY" &&
            report "$num" "Feedback Provided" "the decision is documented — move it to Documented Ready for Sign-Off" ;;
        "Documented Ready for Sign-Off")
          # Back with the owner, and the whole point is that there is something
          # written for him to sign off against. Without it there is nothing to
          # read, and the state is claiming more than the body supports.
          decision_agreed "$DBODY" ||
            report "$num" "Documented Ready for Sign-Off" "nothing is documented to sign off — it belongs in Feedback Provided" ;;
        Decided)
          decision_agreed "$DBODY" ||
            report "$num" "Decided" "marked Decided with no agreed decision in the body" ;;
        Actioned)
          # Not reported. D44: `Actioned` means applied and closed means read,
          # and they are different moments — so an open, Actioned decision is
          # the normal state of one waiting to be read, not an error.
          # `actions.py` shows it as waiting on the owner. Nothing enforces the
          # closing, deliberately: the owner's own answer is that his wish to
          # clear the column will do it, and a reading step is a poor thing to
          # gate on.
          : ;;
      esac
      ;;
  esac
done <<< "$ROWS"

# --- decisions closed before they were finished --------------------------------
#
# The rule is about closing, and nothing intercepts a close: it happens in a
# browser. So this notices afterwards, which is the same shape as every other
# rule here and as verify.sh. A second query because the one above asks only for
# open issues, and a closed decision is precisely the one worth looking at.
#
# Scoped to Decisions and to the most recent hundred, because the archive of
# D1–D38 lives in the glossary and predates the type entirely.
CQ='{repository(owner:"delphside",name:"tile-lite-elite"){issues(first:100,states:CLOSED,orderBy:{field:UPDATED_AT,direction:DESC}){nodes{number issueType{name} body issueFieldValues(first:12){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}'
CLOSED="$(gh api graphql -f query="$CQ" 2>/dev/null || true)"
if [ -n "$CLOSED" ]; then
  while IFS=$'\t' read -r num cstate cb64; do
    [ -n "$num" ] || continue
    DBODY="$(printf '%s' "$cb64" | base64 -d 2>/dev/null || true)"
    [ "$cstate" = "-" ] && cstate=""
    [ "$cstate" = "Actioned" ] ||
      report "$num" "closed" "closed but marked '${cstate:-unset}' — a closed decision is Actioned"
    decision_agreed "$DBODY" || report "$num" "closed" "closed with no agreed decision"
    if decision_has_actions_heading "$DBODY"; then
      N="$(decision_open_actions "$DBODY")"
      [ "$N" = "0" ] || report "$num" "closed" "closed with $N action(s) still open"
    else
      report "$num" "closed" "closed, and has no 'Open actions' heading to check"
    fi
  done <<< "$(printf '%s' "$CLOSED" | jq -r '
    .data.repository.issues.nodes[]
    | select(.issueType.name == "Decision")
    | . as $i
    | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Decision State")|.name][0] // "-") as $ds
    | [$i.number, $ds, (($i.body // "") | @base64)] | @tsv')"
fi

# --- a `no-release` milestone nobody came back to ------------------------------
#
# `no-release` is provisional: it says *not a release* before anybody knows how
# the change will actually reach `main`. It must become `pre-approved` or a
# letter milestone before the issue closes, or the record of how that change
# was delivered is lost — owner, 2026-09-08, and `docs/3.6`.
#
# **Only from 2026-09-04.** `pre-approved` became a milestone that day
# (`66b10c3`); before it, `no-release` had nothing to resolve *to*, so the
# thirty issues closed against it between 13 and 30 August broke no rule that
# existed. Judging them by it would make this report thirty lines long on its
# first run, which is how a check stops being read.
RULE_FROM="2026-09-04"
STALE="$(gh issue list --milestone no-release --state closed \
  --json number,closedAt,title --limit 100 2>/dev/null \
  | jq -r --arg from "$RULE_FROM" \
      '.[] | select(.closedAt >= $from) | [.number, (.title[0:44])] | @tsv' 2>/dev/null || true)"
if [ -n "$STALE" ]; then
  while IFS=$'\t' read -r num title; do
    [ -n "$num" ] || continue
    report "$num" "closed" "closed still on 'no-release' — resolve to pre-approved or a letter"
  done <<< "$STALE"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "  $FAILURES issue(s) are further along than their content supports."
  exit 1
fi
echo "  every open issue has done the work its field claims"
