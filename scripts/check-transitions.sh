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

Q='{repository(owner:"delphside",name:"tile-lite-elite"){issues(first:100,states:OPEN){nodes{number title body issueType{name} parent{number} subIssues(first:30){nodes{number issueType{name}}} issueFieldValues(first:12){nodes{... on IssueFieldSingleSelectValue{name field{... on IssueFieldSingleSelect{name}}}}}}}}}'
ISSUES="$(gh api graphql -f query="$Q" 2>/dev/null)" || {
  echo "check-transitions: could not read the issues" >&2; exit 2; }

echo "==> Issues, against what their fields and titles claim"

ROWS="$(printf '%s' "$ISSUES" | jq -r '
  .data.repository.issues.nodes[] | . as $i
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Stage")|.name][0] // "-") as $stage
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Phase")|.name][0] // "-") as $phase
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Workstream")|.name][0] // "-") as $ws
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Type of change")|.name][0] // "-") as $toc
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Priority")|.name][0] // "-") as $pri
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Effort")|.name][0] // "-") as $eff
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Decision State")|.name][0] // "-") as $dstate
  | ([$i.issueFieldValues.nodes[]? | select(.field.name=="Route")|.name][0] // "-") as $route
  # A parent is a project with **Project** children. `subIssues` also holds
  # folded requirements and the decisions a project owns, so counting them all
  # made every project with a folded source look like a parent — #295, #297 and
  # #301 were all reported as parents that must not build.
  | ([$i.subIssues.nodes[]? | select(.issueType.name == "Project")] | length) as $pkgs
  | (if $i.parent then "sub" elif $pkgs > 0 then "parent" else "solo" end) as $role
  | ([$i.subIssues.nodes[]? | select(.issueType.name == "Requirement") | .number]
     | sort | map(tostring) | join(",")) as $reqkids
  | [$i.number, ($i.issueType.name // ""), $stage, $phase, $ws, $toc, $pri, $eff, $dstate, $route, $role,
     (if $reqkids == "" then "-" else $reqkids end),
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

# Unticked boxes under a heading, by substring. `verify.sh` has the same shape
# in `section_boxes`; this counts rather than prints, because the caller only
# ever asks *how many*.
unticked_under() {
  awk -v h="$2" '
    /^#+[[:space:]]/ { inside = index($0, h) > 0 ? 1 : 0; next }
    inside && /^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]/ { n++ }
    END { print n + 0 }' <<< "$1"
}

# Every field is emitted as "-" when empty, because tab is an IFS whitespace
# character: bash collapses a run of them, so a genuinely empty field would
# merge with the next and shift the body out of reach. That failure is silent —
# the check simply stops finding anything.
while IFS=$'\t' read -r num kind stage phase ws toc pri eff dstate route role reqkids b64 body; do
  [ -n "$num" ] || continue
  for v in stage phase ws toc pri eff dstate route reqkids; do
    [ "${!v}" = "-" ] && printf -v "$v" '%s' ""
  done
  # **No stage means Triage.** Owner, 2026-09-10. An unset field and the first
  # value of a field are the same thing here: a requirement nobody has classified
  # yet. Treating them differently is what let #313, #326, #328, #329, #330 and
  # #336 sit outside every rule — they were typed on 2026-09-10 and still matched
  # no branch below, because the branches key on a stage none of them had.
  #
  # This is the same defect as the untyped one #361 is about, one field along:
  # a rule that reads a field silently exempts every issue where it is empty,
  # and the exemption looks exactly like a pass.
  [ -n "$stage" ] || { [ "$kind" = "Requirement" ] && stage="Triage"; }

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
    Project)
      # **A parent and a work package are both `Project` and owe different
      # things** — D51. The parent owns the requirements, the design and the
      # documents; a package links to them and owes what is its own. Told apart
      # by the parent link: a Project with a parent is a package, one with
      # children is a parent. Requiring the same seven of both would force a
      # one-commit delivery to carry a Requirements table.
      case "$phase" in
        "Design and Test Approach"|Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          if [ "$role" != "sub" ]; then
            printf '%s' "$body" | grep -q "## Requirements" || report "$num" "$phase" "no requirements heading"
            printf '%s' "$body" | grep -q "## Design"       || report "$num" "$phase" "no design heading"
          else
            # A package must point at the design rather than restate it, so an
            # absent link is the defect here — the parent is unreachable from
            # the thing being built.
            printf '%s' "$body" | grep -qE "#[0-9]+" || report "$num" "$phase" "a work package with no link to its parent's design"
          fi
          ;;
      esac
      # **The source requirements are listed as well as parented** — owner,
      # 2026-09-08: *"a project should list its source requirements as well as
      # parenting them. This is separate from the requirements table because
      # that might move on during project scoping."*
      #
      # So there are two records of provenance and they must agree. The `from`
      # column stops being complete the moment scoping merges two sources into
      # one R or drops one; the list does not move. The sub-issues are the third
      # record, and it was the three disagreeing that put #130 and #151 under
      # #294 while #290 carried them as R5 and R6.
      #
      # A project raised directly writes `none`, which is why an absent line and
      # an empty one are different findings — the same reason a test approach
      # that does not apply says "None." rather than being removed.
      case "$phase" in
        "Design and Test Approach"|Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          # **Not asked of a work package** — D51. The parent owns the
          # requirements and therefore their provenance; a package links to them
          # and would otherwise be made to restate a list it does not own.
          srcline="$(printf '%s' "$b64" | base64 -d 2>/dev/null \
            | grep -m1 -iE '^\*\*Source requirements\*\*' || true)"
          if [ "$role" = "sub" ]; then
            :
          elif [ -z "$srcline" ]; then
            report "$num" "$phase" "no 'Source requirements' line, so provenance rests on a table that scoping rewrites"
          else
            # **Its own number is not a source it can parent.** A project
            # converted from a requirement *is* that requirement — #252 says so
            # in its line — and nothing can be its own sub-issue.
            # **`|| true` on both, because `grep` exits 1 on no match and this
            # script runs under `pipefail`.** #288 lists `none — raised directly`
            # and has no numbers at all, so the pipeline failed, the script died
            # before its summary, and it reported *nothing* while exiting 1. The
            # fifth time a grep in a pipeline has silently broken a check here.
            listed="$(printf '%s' "$srcline" | grep -oE '#[0-9]+' | tr -d '#' \
              | grep -vx "$num" | sort -un | tr '\n' ' ' || true)"
            held="$(printf '%s' "$reqkids" | tr ',' '\n' | grep . | sort -un | tr '\n' ' ' || true)"
            for r in $listed; do
              case " $held " in *" $r "*) : ;;
                *) report "$num" "$phase" "lists #$r as a source but does not parent it" ;;
              esac
            done
            for r in $held; do
              case " $listed " in *" $r "*) : ;;
                *) report "$num" "$phase" "parents #$r but does not list it as a source" ;;
              esac
            done
          fi
          ;;
      esac
      # **Route, from `Design and Test Approach`** — #346 R3. By that phase the
      # design is done, so how the change reaches its users is knowable, and
      # `Route` is what `status.sh` answers "does this reach users?" from. It
      # can be known earlier and often is: the owner, 2026-09-08, on #71's work
      # packages — *"all the #71 work packages are Project Release, even if we
      # haven't written the scope yet."* This is the latest it may be unset,
      # not the earliest it may be set.
      #
      # **A parent is not asked.** Owner, same day: *"It may be better to say
      # parents don't need a route. You could derive one from the sub-projects,
      # but it would just be for information."*
      #
      # Nothing checked this until 2026-09-08, when a hand scan found twenty
      # projects with no route.
      case "$phase" in
        "Design and Test Approach"|Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          if [ "$role" != "parent" ]; then
            [ -n "$route" ] || report "$num" "$phase" "no route, so nothing can say whether this reaches users"
          fi
          ;;
      esac
      # **A parent never reaches these.** Oversight is a design role: it holds
      # the requirements and the design while packages are built against them,
      # and never acquires a delivery role. `Post-deployment` is allowed, for a
      # requirement no single delivery satisfies, and `Project Closedown` to
      # close.
      if [ "$role" = "parent" ]; then
        case "$phase" in
          Development|"User testing"|Deployment)
            report "$num" "$phase" "a parent does not build or ship — that is a work package phase" ;;
        esac
      fi
      # **Not asked of a parent.** A test approach and an artefact list belong to
      # the thing being built, and a parent builds nothing — D51. It owns the
      # requirements, the design and the documents; the package owns these.
      case "$phase" in
        Development|"User testing"|Deployment|Post-deployment|"Project Closedown")
          if [ "$role" != "parent" ]; then
            printf '%s' "$body" | grep -q "## Test approach"       || report "$num" "$phase" "no test approach"
            printf '%s' "$body" | grep -q "Technical tests"        || report "$num" "$phase" "test approach has no Preview/Rehearsal lists"
            printf '%s' "$body" | grep -q "## Impacted artefacts"  || report "$num" "$phase" "no impacted artefacts"
          fi
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
          # **A work package may delegate lessons learnt to the parent** (D51),
          # and says so — `Delegated to #<parent>` — so one project does not
          # produce four sections saying the same thing. The delegation is
          # written rather than implied, or this reads an omission as an answer.
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
# **`first:100` is a page, and there are 265 closed issues.** Ordered by
# `UPDATED_AT` so the page holds what moved most recently, which is what the
# Decision rules want. The closed-project rule below wants the opposite — an old
# project closed with a box unticked is exactly the one nobody has looked at —
# so it reads its own list through `gh issue list --limit`, which paginates.
# #377 is the same defect one collection along.
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

# --- a closed project with an unticked box --------------------------------------
#
# **A project can close carrying an undone action and nothing says so** — #357.
# #174 closed on 2026-08-24 with an open action that its *own* Delivery 1 had
# unblocked two days earlier; it surfaced a fortnight later as #356.
#
# Nothing covered it. `verify.sh` reads open projects **in the current
# milestone** only, the rules above read **open** issues, and the closed sweep
# above reads Decisions. So a project's boxes stop being read the moment it
# closes, which is the moment nobody is looking.
#
# **`## Open actions` is read as well as the two test headings.** It is the
# section that held the lost action and was invisible to everything — the
# Decision rules read it, and nothing read it for a project.
#
# **Reported, never refused**, per #346 R6: a box is ticked in a browser and
# nothing can stand in front of that. An unticked box is not always wrong —
# #240 carries a documented untested item with the reason written beside it,
# which is a legitimate answer. This does not try to tell the two apart, and
# that is deliberate: the defect #357 names is that **neither** was reported, so
# reporting both is the fix. Judging which is which is a content question and
# belongs with #346.
#
# `--limit 500` paginates, unlike the `first:100` above. The oldest closed
# project is the one least likely to have been looked at.
CLOSED_PROJECTS="$(gh issue list --state closed --limit 500 \
  --json number,title,issueType,body \
  --jq '.[] | select(.issueType.name == "Project") | [.number, (.title[0:44]), (.body // "" | @base64)] | @tsv' \
  2>/dev/null || true)"
if [ -n "$CLOSED_PROJECTS" ]; then
  while IFS=$'\t' read -r num title cb64; do
    [ -n "$num" ] || continue
    CBODY="$(printf '%s' "$cb64" | base64 -d 2>/dev/null || true)"
    [ -n "$CBODY" ] || continue
    FN="$(unticked_under "$CBODY" "Functional user tests")"
    TE="$(unticked_under "$CBODY" "Technical tests")"
    OA="$(unticked_under "$CBODY" "Open actions")"
    TOTAL=$(( FN + TE + OA ))
    if [ "$TOTAL" != "0" ]; then
      WHERE=""
      [ "$FN" != "0" ] && WHERE="$WHERE ${FN} preview"
      [ "$TE" != "0" ] && WHERE="$WHERE ${TE} rehearsal"
      [ "$OA" != "0" ] && WHERE="$WHERE ${OA} open action(s)"
      report "$num" "closed" "closed with unticked boxes —$WHERE. Tick them, or write the answer beside each"
    fi
  done <<< "$CLOSED_PROJECTS"
fi

# --- two decisions carrying the same number -----------------------------------
#
# The `D` number is typed into the title by hand, read off a list of the ones
# that already exist, and nothing compares them. #333 and #337 were both **D48**
# on 2026-09-06, and it was found only by reading a pull request body that cited
# D48 and meant the other one — #339 R2.
#
# **What it costs is a citation.** A decision number is a link: `docs/3.3` and a
# dozen issue bodies say "D42 decided this". Two decisions with one number make
# every such reference ambiguous, including the ones already written, and the
# damage is retrospective — #335's body was correct when written and is not now.
#
# Nothing else in this script can see it, because the number is not a field.
# `--limit 500` rather than a bare list: `gh issue list` paginates internally up
# to the limit, and #377 was an unpaginated read that went stale the moment the
# collection outgrew one page.
DECS="$(gh issue list --state all --limit 500 --json number,title,issueType \
  --jq '.[] | select(.issueType.name == "Decision") | [.number, .title] | @tsv' 2>/dev/null || true)"
if [ -n "$DECS" ]; then
  # First `D<digits>` in the title. "[Decision]:" cannot match — its D is
  # followed by a letter — so the first hit is the number itself.
  DUPES="$(printf '%s\n' "$DECS" | awk -F'\t' '
    { if (match($2, /D[0-9]+/)) {
        d = substr($2, RSTART, RLENGTH); seen[d] = seen[d] " #" $1; count[d]++ } }
    END { for (d in count) if (count[d] > 1) print d "\t" seen[d] }')"
  if [ -n "$DUPES" ]; then
    while IFS=$'\t' read -r dnum issues; do
      [ -n "$dnum" ] || continue
      first="$(printf '%s' "$issues" | awk '{ print $1 }' | tr -d '#')"
      report "$first" "duplicate" "$dnum is used by$issues — renumber the later one and fix its citations"
    done <<< "$DUPES"
  fi
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


# --- a work package title, against the milestones of its siblings --------------
#
# **The delivery is the milestone, so every count in a title is derivable.** A
# title reads `#N WP A Del 1 of 2, pt 1 of 2:` — which package, which delivery
# carries it, and its share of that delivery. All three are readable from the
# siblings, so none of them has to be trusted.
#
# Owner, 2026-09-08: *"of course the number of deliveries may change, but it is
# still better to have it."* The counts are kept knowing they go stale; this is
# what makes the staleness report itself instead of waiting to be noticed. Six
# titles were wrong the day before this was written.
#
# `gh issue list --json` carries `parent`, so one call covers every project in
# either state — the GraphQL query above reads open issues only, and a parent
# routinely has closed packages.
#
# **A quoted heredoc, not a single-quoted string.** The jq program has
# apostrophes in its comments, and embedding it in `'...'` ended the string
# mid-program — the same defect that broke this file once before.
WPQ="$(cat <<'JQEOF'
# Every work package title, judged against the milestones of its siblings.
[ .[] | select(.issueType.name == "Project") | select(.parent != null)
      | {num: .number, title: .title, parent: .parent.number,
         ms: (.milestone.title // "")} ]
| group_by(.parent)
| map(
    . as $kids
    | ([$kids[].ms] | map(select(. != "")) | unique) as $dels
    | ($dels | length) as $ndel
    # **The delivery count is only knowable once every package has a milestone.**
    # An unset milestone is a delivery not yet decided, not a delivery that does
    # not exist: #214 has two by design while #355 is unscoped, so counting
    # distinct milestones gives one and would call a correct title wrong.
    # Gates every count, `pt` included. #71's five packages all carry `1.0.0`,
    # which is a *target* rather than a settled delivery — the owner, 2026-09-08:
    # a milestone on an unscoped project says intent, not grouping. Demanding
    # `pt 1 of 5` there would write a grouping into five titles that the design
    # has not yet made.
    | ([$kids[] | select(.ms == "")] | length == 0) as $settled
    | $kids[]
    | . as $k
    # `// null`, because a non-matching `capture` yields *empty*, not null — so
    # binding it directly made the whole branch produce nothing and the
    # unrecognised-title check could never fire. Found by the synthetic case.
    | (($k.title | capture("^#(?<par>[0-9]+) WP (?<wp>[A-Z]+)(?: Del (?<dk>[0-9]+) of (?<dj>[0-9]+))?(?:, pt (?<pp>[0-9]+) of (?<pq>[0-9]+))?:")) // null) as $c
    | ([$kids[] | select(.ms == $k.ms and .ms != "")] | length) as $share
    | [
        (if $c == null then [$k.num, "title", "does not follow '#N WP A Del K of J: what it delivers'"] else empty end),
        (if $c != null and ($c.par | tonumber) != $k.parent
           then [$k.num, "title", "names #\($c.par) but its parent is #\($k.parent)"] else empty end),
        (if $c != null and $c.dj == null and $settled and $ndel > 0
           then [$k.num, "title", "no 'Del K of J', but its siblings' milestones give \($ndel) deliver\(if $ndel == 1 then "y" else "ies" end)"] else empty end),
        (if $c != null and $c.dj != null and $settled and ($c.dj | tonumber) != $ndel
           then [$k.num, "title", "says 'of \($c.dj)' deliveries; the milestones give \($ndel)"] else empty end),
        (if $c != null and $settled and $share > 1 and $c.pq == null
           then [$k.num, "title", "shares milestone '\($k.ms)' with \($share - 1) other, so it needs 'pt P of \($share)'"] else empty end),
        (if $c != null and $settled and $share == 1 and $c.pq != null
           then [$k.num, "title", "carries 'pt' but is alone in milestone '\($k.ms)'"] else empty end),
        (if $c != null and $settled and $c.pq != null and ($c.pq | tonumber) != $share
           then [$k.num, "title", "says 'pt of \($c.pq)'; \($share) package(s) share milestone '\($k.ms)'"] else empty end)
      ][]
  )
| .[]
| @tsv
JQEOF
)"
WPFINDINGS="$(gh issue list --state all --limit 500 \
  --json number,title,state,milestone,parent,issueType 2>/dev/null \
  | jq -r "$WPQ" 2>/dev/null || true)"
if [ -n "$WPFINDINGS" ]; then
  while IFS=$'\t' read -r num label msg; do
    [ -n "$num" ] || continue
    report "$num" "$label" "$msg"
  done <<< "$WPFINDINGS"
fi


# --- a closed work package with no milestone -----------------------------------
ABSQ="$(cat <<'JQEOF'
# A closed work package that never carried a milestone.
#
# A work package exists to deliver, so a closed one has a milestone naming the
# delivery it went out in. A closed package with none either delivered and was
# never recorded, or was never a work package at all — the shape #294 had on
# 2026-09-06, when a `Project` was absorbed into #290 using the requirement fold:
# made a sub-issue, closed, and left claiming to be a package that would ship.
[ .[] | select(.issueType.name == "Project") | select(.parent != null)
      | select(.state == "CLOSED")
      | select((.milestone // null) == null)
      | [.number, "closed", "a closed work package of #\(.parent.number) with no milestone — it delivered and was not recorded, or it was absorbed and should not be a sub-issue"] ]
| .[] | @tsv
JQEOF
)"
ABSFINDINGS="$(gh issue list --state all --limit 500 \
  --json number,title,state,milestone,parent,issueType 2>/dev/null \
  | jq -r "$ABSQ" 2>/dev/null || true)"
if [ -n "$ABSFINDINGS" ]; then
  while IFS=$'\t' read -r num label msg; do
    [ -n "$num" ] || continue
    report "$num" "$label" "$msg"
  done <<< "$ABSFINDINGS"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "  $FAILURES finding(s): content that does not support the field, or a title that disagrees with the milestones."
  exit 1
fi
echo "  every issue has done the work its fields claim, and every title agrees"
