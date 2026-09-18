#!/usr/bin/env bash
set -euo pipefail

# board-model.test.sh — the board model's derived facts, #383.
#
# Every fact the model derives is one a script used to derive for itself, and
# the ones that broke are the ones tested here. No network: canned issues only.
#
#   classify          parentage, which was wrong twice — #297, #375
#   defaults          untyped -> Requirement, unset Stage -> Triage
#   section scoping   counting boxes across the whole body reported #252's
#                     answered post-deployment checks as unanswered, because
#                     its Test approach boxes were the unticked ones

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue, classify
from board.obligations import Answer, assess
from board.sources import pr_state
from board.turn import waiting_on_owner

failures = 0

def check(what, want, got):
    global failures
    if got == want:
        print(f"  ok   {what}")
    else:
        print(f"  FAIL {what}\n       want {want!r}\n       got  {got!r}")
        failures += 1

def issue(number=1, kind="Project", fields=None, subs=(), parent=None,
          body="", milestone=None):
    return RawIssue(number, "t", "OPEN", body, kind, fields or {},
                    tuple(subs), parent, milestone, frozenset())

print("classify: a parent is a project with PROJECT sub-issues")

# #214 as it is: two work packages and two folded requirements.
raw = issue(214, subs=[RawSubIssue(354, "Project"), RawSubIssue(355, "Project"),
                       RawSubIssue(134, "Requirement"), RawSubIssue(193, "Requirement")])
check("two packages and two folded requirements -> ParentProject",
      "ParentProject", classify(raw).kind)

# The narrow case: folded requirements only. Still one delivery, owes a route.
raw = issue(9, subs=[RawSubIssue(1, "Requirement"), RawSubIssue(2, "Requirement")])
check("folded requirements only -> StandaloneProject",
      "StandaloneProject", classify(raw).kind)

check("no sub-issues, no parent -> StandaloneProject",
      "StandaloneProject", classify(issue(9)).kind)
check("no sub-issues, has a parent -> WorkPackage",
      "WorkPackage", classify(issue(9, parent=214)).kind)

print()
print("a parent owes no route, a delivery owes one")
parent = classify(issue(1, subs=[RawSubIssue(2, "Project")],
                        fields={"Route": "Repository Change"}))
ids = {f.obligation.id: f.answer for f in assess(parent)}
check("a parent with a Route set reports it missing",
      Answer.MISSING, ids.get("parent-no-route"))
check("a parent is never asked for a Route", None, ids.get("delivery-route"))

wp = classify(issue(1, parent=2, fields={}))
ids = {f.obligation.id: f.answer for f in assess(wp)}
check("a work package with no Route reports it missing",
      Answer.MISSING, ids.get("delivery-route"))

print()
print("defaults, and both are flagged")
untyped = classify(issue(1, kind=None))
check("untyped -> Requirement", "Requirement", untyped.kind)
check("and the default is flagged", True, untyped.type_was_defaulted)
check("an unset Stage reads as Triage", "Triage", untyped.step)
check("and that default is flagged too", True, untyped.stage_was_defaulted)
ids = {f.obligation.id: f.answer for f in assess(untyped)}
check("a defaulted type is reported, not silently accepted",
      Answer.MISSING, ids.get("type-set"))

typed = classify(issue(1, kind="Requirement", fields={"Stage": "On Hold"}))
check("a set Stage is not defaulted", False, typed.stage_was_defaulted)
check("and is read as itself", "On Hold", typed.step)

print()
print("box counting is scoped to the section that owns it")
# #252's shape: post-deployment answered, Test approach boxes unticked.
body = """## Test approach

### Functional user tests — Preview

- [ ] a thing nobody has ticked

## Post-deployment checks against requirements

| requirement | how | |
| --- | --- | --- |
| R1 | read it | **passed** |
"""
i = classify(issue(252, parent=9, fields={"Phase": "Post-deployment",
                                          "Route": "Repository Change"},
                   body=body, milestone="pre-approved"))
check("unticked boxes across the whole body", 1, i.unticked_boxes)
check("unticked inside the post-deployment section", 0,
      i.unticked_in("Post-deployment checks against requirements"))
ids = {f.obligation.id: f.answer for f in assess(i)}
check("answered post-deployment checks are not reported as missing",
      Answer.MET, ids.get("wp-post-deployment"))

print()
print("a decision ships nothing, so it owes no milestone")
d = classify(issue(382, kind="Decision", fields={"Decision State": "Decided"},
                   body="## Agreed Decision\n\nAccepted.\n"))
ids = {f.obligation.id: f.answer for f in assess(d)}
check("a decision with no milestone is fine", Answer.MET,
      ids.get("decision-no-milestone"))
check("a decision is never asked for a Route", None, ids.get("delivery-route"))
check("nor for a delivery milestone", None, ids.get("wp-milestone"))

d = classify(issue(382, kind="Decision", fields={"Decision State": "Decided"},
                   milestone="0.8.1", body="## Agreed Decision\n\nAccepted.\n"))
ids = {f.obligation.id: f.answer for f in assess(d)}
check("a decision carrying a milestone is reported", Answer.MISSING,
      ids.get("decision-no-milestone"))

print()
print("a section includes its subheadings")
body = """## Test approach

### Functional user tests — Preview

- [x] somebody used it

### Technical tests — Rehearsal

- [x] and measured it

## Deliveries

One.
"""
i = classify(issue(363, kind="Project", body=body))
check("content under ### subheadings is part of the ## section",
      True, len(i.section("Test approach")) > 20)
check("and the next ## heading ends it",
      False, "One." in i.section("Test approach"))
check("ticks inside a subsection are counted",
      2, i.ticked_in("Test approach"))

print()
print("an obligation nothing can evidence is 'not checked', never 'met'")
ready = classify(issue(1, kind="Requirement",
                       fields={"Stage": "Ready for Project", "Workstream": "W"}))
ids = {f.obligation.id: f.answer for f in assess(ready)}
check("a gap row answers not checked", Answer.NOT_CHECKED, ids.get("ready-complete"))

print()
print("a pull request is not an issue, and must still reach the model")
# GraphQL's `issues` connection excludes pull requests, so a snapshot built
# from it alone contains no PullRequest at all: classify never reaches that
# branch, both PR obligations apply to nothing, and R1 cannot see a review
# waiting. Every one of those reads as "nothing to report".
pr = classify(issue(391, kind="PullRequest", fields={"PR State": "Awaiting review"},
                    body="Refs #301\n\n## What is being requested\n\nx\n\n"
                         "## What is deliberately left out\n\ny\n"))
check("a pull request classifies as one", "PullRequest", pr.kind)
ids = {f.obligation.id: f.answer for f in assess(pr)}
check("a linked issue is found", Answer.MET, ids.get("pr-linked"))
check("both scope headings are found", Answer.MET, ids.get("pr-scope-stated"))
# The grid says what a pull request owes: a linked issue, the two headings,
# the review, CI. A workstream is not on it -- a pull request is a change
# vehicle and its workstream is that of the issue it refs.
check("a pull request is never asked for a workstream", None, ids.get("workstream"))

no_ref = classify(issue(390, kind="PullRequest", fields={"PR State": "Approved"},
                        body="Scope of this delivery: things.\n"))
ids = {f.obligation.id: f.answer for f in assess(no_ref)}
check("a pull request with no Refs is reported", Answer.MISSING, ids.get("pr-linked"))
check("and one with neither heading is too", Answer.MISSING, ids.get("pr-scope-stated"))

print()
print("PR State is read with sync-pr-state.sh's ladder, in its order")
# Two answers to one question is the disagreement this model exists to remove.
check("draft beats everything, approval included",
      "Drafting", pr_state(True, "APPROVED", 1))
check("approved", "Approved", pr_state(False, "APPROVED", 0))
check("changes requested", "Changes requested", pr_state(False, "CHANGES_REQUESTED", 1))
check("a requested reviewer and no decision is awaiting review",
      "Awaiting review", pr_state(False, None, 1))
check("no reviewer and no decision is still drafting",
      "Drafting", pr_state(False, None, 0))

print()
print("R1 sees only what the owner must do")
check("a review waiting is his", "pull request",
      getattr(waiting_on_owner(pr), "source", None))
check("an approved one is not",
      None, waiting_on_owner(classify(issue(1, kind="PullRequest",
                                            fields={"PR State": "Approved"}))))
check("an unanswered decision is his", "decision",
      getattr(waiting_on_owner(classify(issue(1, kind="Decision",
                                              fields={"Decision State": "Asked"}))),
              "source", None))
check("a decided one is not", None,
      waiting_on_owner(classify(issue(1, kind="Decision",
                                      fields={"Decision State": "Decided"}))))
wp = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                    body="## Functional user tests — Preview\n\n- [ ] click it\n"))
check("an untested delivery is his", "user testing",
      getattr(waiting_on_owner(wp), "source", None))
done = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                      body="## Functional user tests — Preview\n\n- [x] clicked\n"))
check("a tested one is not", None, waiting_on_owner(done))

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all board model cases hold")
PY
