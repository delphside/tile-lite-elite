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
from board.turn import (REVIEW_DUE_DAYS, boxes_are_due, waiting_on_claude,
                        waiting_on_owner, whats_waiting)
from board.sources import Snapshot

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
print("a post-deployment check is answered, not merely present")
# **#346 R4, restored.** The checks are a table with an answer column, and the
# model counted only boxes -- so a section of blank answers read as complete.
# #374 closed on 2026-09-18 with R1 and R2 unanswered and the model said
# "complete, 0 not checked". The rule existed in check-transitions.sh and did
# not survive its retirement into this model.
blank = """## Post-deployment checks against requirements

| requirement | how | |
| --- | --- | --- |
| R1 | read it | **passed** |
| R2 | look at it | |
"""
i = classify(issue(374, parent=9, fields={"Phase": "Post-deployment",
                                          "Route": "Repository Change"},
                   body=blank, milestone="pre-approved"))
check("a blank answer cell is one unanswered row", 1,
      i.unanswered_rows_in("Post-deployment checks against requirements"))
ids = {f.obligation.id: f.answer for f in assess(i)}
check("and the obligation is not met", Answer.MISSING,
      ids.get("wp-post-deployment"))

# The other half, which is what stops it crying wolf: an answer in prose is
# still an answer. The bash rule demanded passed/cannot be tested/failed and
# would have flagged this.
prose = blank.replace("| R2 | look at it | |",
                      "| R2 | look at it | measured on the 9th: it does not |")
i = classify(issue(374, parent=9, fields={"Phase": "Post-deployment",
                                          "Route": "Repository Change"},
                   body=prose, milestone="pre-approved"))
ids = {f.obligation.id: f.answer for f in assess(i)}
check("an answer in other words is still an answer", Answer.MET,
      ids.get("wp-post-deployment"))

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
print("a project owes effort and priority once scoping is claimed settled")
# #346: reaching a queue phase asserts scoping is finished. Restored
# 2026-09-19 -- dropped silently when check-transitions.sh (582fed8) retired
# in favour of this model, and the live board still shows #71 and #290 (a
# parent and a work package, both at Q1) missing exactly what #346 found
# them missing on 2026-09-17, unreported by this model until now.
at_scope = classify(issue(1, kind="Project",
                          fields={"Phase": "Scope", "Workstream": "W"}))
ids = {f.obligation.id: f.answer for f in assess(at_scope)}
check("Scope is the initial value and is exempt", None, ids.get("project-effort"))
check("both fields exempt at Scope", None, ids.get("project-priority"))

in_queue = classify(issue(71, kind="Project",
                          fields={"Phase": "Q1", "Workstream": "W"}))
ids = {f.obligation.id: f.answer for f in assess(in_queue)}
check("reaching the queue with no effort is reported",
      Answer.MISSING, ids.get("project-effort"))
check("and no priority is reported the same way",
      Answer.MISSING, ids.get("project-priority"))

scoped_wp = classify(issue(268, parent=71, fields={
    "Phase": "Q1", "Workstream": "W", "Effort": "Low", "Priority": "High"}))
ids = {f.obligation.id: f.answer for f in assess(scoped_wp)}
check("a work package with both fields set passes",
      Answer.MET, ids.get("project-effort"))
check("both", Answer.MET, ids.get("project-priority"))

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
print("an age is named for what it is")
from board.turn import Waiting
from dataclasses import replace as _replace
w = Waiting(classify(issue(1, kind="Requirement")), "do it", "checkbox")
check("no age at all falls back to nothing and reads as today",
      True, "(today)" in w.line)
dated = _replace(w, days=12.4, dated=True)
check("a timeline age says waiting", True, "12d waiting" in dated.line)
guessed = _replace(w, days=12.4, dated=False)
# `quiet` is the weaker claim: last activity of any kind, which a comment
# resets. Naming them the same would let the weaker read as the stronger.
check("a fallback age says quiet, not waiting", True, "12d quiet" in guessed.line)
check("and never claims to be waiting", False, "waiting" in guessed.line)

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
print("the mirror: what is waiting on Claude")
def issue2(number, kind="Project", parent=None, fields=None, labels=(), body=""):
    return RawIssue(number, f"issue {number}", "OPEN", body, kind, fields or {},
                    (), parent, None, frozenset(labels))

live = classify(issue2(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"}))
check("a delivery at Post-deployment owes a review", "post-deployment",
      getattr(waiting_on_claude(live), "source", None))
# #310: a Release Check project waits for the next release and owes nobody an
# action. Without this it nags for a review for ever.
held = classify(issue2(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"},
                       labels=["Release Check"]))
check("unless it is waiting for a release", None, waiting_on_claude(held))
check("an approved pull request is Claude's to merge", "pull request",
      getattr(waiting_on_claude(classify(issue2(
          1, kind="PullRequest", fields={"PR State": "Approved"}))), "source", None))
check("one awaiting review is not", None,
      waiting_on_claude(classify(issue2(1, kind="PullRequest",
                                        fields={"PR State": "Awaiting review"}))))
check("and that one is the owner's", "pull request",
      getattr(waiting_on_owner(classify(issue2(1, kind="PullRequest",
                                               fields={"PR State": "Awaiting review"}))),
              "source", None))

print()
print("a review is not due until it has waited")
# Dropped only once the age is KNOWN. Without a date there is nothing to
# compare, and guessing "probably old enough" would claim work is owed when
# nothing says so.
snap = Snapshot((issue2(1, parent=2, fields={"Phase": "Post-deployment",
                                             "Route": "x"}),), 0.0, 0.0, 1, False)
got = whats_waiting(snap, dated=False, who="Claude")
check("an undated review is kept, not guessed away", 1, len(got))
check("and the threshold it is waiting for is recorded",
      REVIEW_DUE_DAYS, got[0].due_after)

print()
print("every checkbox says whose move it is")
body = """## Functional user tests — Preview

- [ ] **owner** — click it
- [x] **Claude** — wrote the test

## Technical tests — Rehearsal

- [ ] **Claude** — run the script
- [ ] nobody owns this one
"""
i = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                   body=body))
check("four boxes are found", 4, len(i.boxes))
check("one is the owner's and unticked", 1, len(i.unticked_for("owner")))
check("one is Claude's and unticked", 1, len(i.unticked_for("Claude")))
check("the unlabelled one is counted, not assigned", 1, len(i.unlabelled_boxes))
check("a ticked box is not waiting", "wrote the test", i.boxes[1].text)
check("the label is stripped from the text", "click it", i.boxes[0].text)
ids = {f.obligation.id: f.answer for f in assess(i)}
check("an unlabelled box is reported", Answer.MISSING, ids.get("boxes-labelled"))

clean = classify(issue(1, kind="Requirement",
                       body="- [ ] **Claude** — do it\n- [x] **owner** — judged\n"))
check("a fully labelled body passes", Answer.MET,
      {f.obligation.id: f.answer for f in assess(clean)}.get("boxes-labelled"))
check("an em dash is not required", 1,
      len(classify(issue(1, body="- [ ] **owner** - hyphen works\n")).unticked_for("owner")))

print()
print("a box is not waiting until it is due")
# Labelling made 126 boxes visible at once. Listing every one of the owner's
# turns R1 into everything that will ever need him, which is the report that
# gets skimmed.
req = classify(issue(1, kind="Requirement", fields={"Stage": "Triage"},
                     body="- [ ] **owner** — future evidence\n"))
check("a requirement's evidence box is never due", False, boxes_are_due(req))
check("so it is not reported as waiting", None, waiting_on_owner(req))
scoped = classify(issue(1, parent=2, fields={"Phase": "Scope", "Route": "x"},
                        body="- [ ] **owner** — a test written early\n"))
check("a delivery still in Scope is not due", False, boxes_are_due(scoped))
live = classify(issue(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"},
                      body="- [ ] **owner** — did the benefit arrive\n"))
check("one at Post-deployment is", True, boxes_are_due(live))
check("and it reports as the owner's", "checkbox",
      getattr(waiting_on_owner(live), "source", None))

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all board model cases hold")
PY
