"""the board model's derived facts, #383.

Every fact the model derives is one a script used to derive for itself, and
the ones that broke are the ones tested here. No network: canned issues only.

  classify          parentage, which was wrong twice — #297, #375
  defaults          untyped -> Requirement, unset Stage -> Triage
  section scoping   counting boxes across the whole body reported #252's
                    answered post-deployment checks as unanswered, because
                    its Test approach boxes were the unticked ones"""

import unittest

from .cases import Cases

from board.model import RawIssue, RawSubIssue, classify
from board.obligations import Answer, assess
from board.sources import pr_state
from board.turn import (REVIEW_DUE_DAYS, boxes_are_due, due_boxes,
                        waiting_on_claude, waiting_on_owner, whats_waiting)
from board.sources import Snapshot


def issue(number=1, kind="Project", fields=None, subs=(), parent=None,
          body="", milestone=None):
    return RawIssue(number, "t", "OPEN", body, kind, fields or {},
                    tuple(subs), parent, milestone, frozenset())

from board.turn import Waiting
from dataclasses import replace as _replace
def issue2(number, kind="Project", parent=None, fields=None, labels=(), body=""):
    return RawIssue(number, f"issue {number}", "OPEN", body, kind, fields or {},
                    (), parent, None, frozenset(labels))

def due(body, **fields):
    f = {"Phase": "Scope", "Route": "x"}
    f.update(fields)
    return classify(issue(1, parent=2, fields=f, body=body))

import board.repo as _repo
import board.turn as _turn
from board.sources import Snapshot



# A pull request awaiting review, shared by the pull-request and R1 cases.
pr = classify(issue(391, kind="PullRequest", fields={"PR State": "Awaiting review"},
                    body="Refs #301\n\n## What is being requested\n\nx\n\n"
                         "## What is deliberately left out\n\ny\n"))


class TheBoardModel(Cases):

    def test_classify_a_parent_is_a_project_with_project_sub_issues(self):
        """classify: a parent is a project with PROJECT sub-issues"""
        # #214 as it is: two work packages and two folded requirements.
        raw = issue(214, subs=[RawSubIssue(354, "Project"), RawSubIssue(355, "Project"),
                               RawSubIssue(134, "Requirement"), RawSubIssue(193, "Requirement")])
        self.expect("two packages and two folded requirements -> ParentProject",
              "ParentProject", classify(raw).kind)

        # The narrow case: folded requirements only. Still one delivery, owes a route.
        raw = issue(9, subs=[RawSubIssue(1, "Requirement"), RawSubIssue(2, "Requirement")])
        self.expect("folded requirements only -> StandaloneProject",
              "StandaloneProject", classify(raw).kind)

        self.expect("no sub-issues, no parent -> StandaloneProject",
              "StandaloneProject", classify(issue(9)).kind)
        self.expect("no sub-issues, has a parent -> WorkPackage",
              "WorkPackage", classify(issue(9, parent=214)).kind)

    def test_a_parent_owes_no_route_a_delivery_owes_one(self):
        """a parent owes no route, a delivery owes one"""
        parent = classify(issue(1, subs=[RawSubIssue(2, "Project")],
                                fields={"Route": "Programme Tooling and Docs"}))
        ids = {f.obligation.id: f.answer for f in assess(parent)}
        self.expect("a parent with a Route set reports it missing",
              Answer.MISSING, ids.get("parent-no-route"))
        self.expect("a parent is never asked for a Route", None, ids.get("delivery-route"))

        wp = classify(issue(1, parent=2, fields={}))
        ids = {f.obligation.id: f.answer for f in assess(wp)}
        self.expect("a work package with no Route reports it missing",
              Answer.MISSING, ids.get("delivery-route"))

    def test_defaults_and_both_are_flagged(self):
        """defaults, and both are flagged"""
        untyped = classify(issue(1, kind=None))
        self.expect("untyped -> Requirement", "Requirement", untyped.kind)
        self.expect("and the default is flagged", True, untyped.type_was_defaulted)
        self.expect("an unset Stage reads as Triage", "Triage", untyped.step)
        self.expect("and that default is flagged too", True, untyped.stage_was_defaulted)
        ids = {f.obligation.id: f.answer for f in assess(untyped)}
        self.expect("a defaulted type is reported, not silently accepted",
              Answer.MISSING, ids.get("type-set"))

        typed = classify(issue(1, kind="Requirement", fields={"Stage": "On Hold"}))
        self.expect("a set Stage is not defaulted", False, typed.stage_was_defaulted)
        self.expect("and is read as itself", "On Hold", typed.step)

    def test_which_stage_is_written_onto_the_board(self):
        """a new requirement's Stage is recorded; nothing else is given one"""
        new = classify(issue(1, kind="Requirement"))
        self.expect("a typed requirement with no Stage is given Triage",
                    "Triage", new.stage_to_record)
        staged = classify(issue(1, kind="Requirement", fields={"Stage": "On Hold"}))
        self.expect("a set Stage is never overwritten", None, staged.stage_to_record)
        untyped = classify(issue(1, kind=None))
        self.expect("an untyped issue is not, since it may become a project",
                    None, untyped.stage_to_record)
        for kind in ("Project", "Decision"):
            other = classify(issue(1, kind=kind))
            self.expect(f"a {kind} has no Stage to record, owning a different field",
                        None, getattr(other, "stage_to_record", None))

    def test_box_counting_is_scoped_to_the_section_that_owns_it(self):
        """box counting is scoped to the section that owns it"""
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
                                                  "Route": "Programme Tooling and Docs"},
                           body=body, milestone="pre-approved"))
        self.expect("unticked boxes across the whole body", 1, i.unticked_boxes)
        self.expect("unticked inside the post-deployment section", 0,
              i.unticked_in("Post-deployment checks against requirements"))
        ids = {f.obligation.id: f.answer for f in assess(i)}
        self.expect("answered post-deployment checks are not reported as missing",
              Answer.MET, ids.get("wp-post-deployment"))

    def test_a_post_deployment_check_is_answered_not_merely_present(self):
        """a post-deployment check is answered, not merely present"""
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
                                                  "Route": "Programme Tooling and Docs"},
                           body=blank, milestone="pre-approved"))
        self.expect("a blank answer cell is one unanswered row", 1,
              i.unanswered_rows_in("Post-deployment checks against requirements"))
        ids = {f.obligation.id: f.answer for f in assess(i)}
        self.expect("and the obligation is not met", Answer.MISSING,
              ids.get("wp-post-deployment"))

        # The other half, which is what stops it crying wolf: an answer in prose is
        # still an answer. The bash rule demanded passed/cannot be tested/failed and
        # would have flagged this.
        prose = blank.replace("| R2 | look at it | |",
                              "| R2 | look at it | measured on the 9th: it does not |")
        i = classify(issue(374, parent=9, fields={"Phase": "Post-deployment",
                                                  "Route": "Programme Tooling and Docs"},
                           body=prose, milestone="pre-approved"))
        ids = {f.obligation.id: f.answer for f in assess(i)}
        self.expect("an answer in other words is still an answer", Answer.MET,
              ids.get("wp-post-deployment"))

    def test_a_decision_ships_nothing_so_it_owes_no_milestone(self):
        """a decision ships nothing, so it owes no milestone"""
        d = classify(issue(382, kind="Decision", fields={"Decision State": "Decided"},
                           body="## Agreed Decision\n\nAccepted.\n"))
        ids = {f.obligation.id: f.answer for f in assess(d)}
        self.expect("a decision with no milestone is fine", Answer.MET,
              ids.get("decision-no-milestone"))
        self.expect("a decision is never asked for a Route", None, ids.get("delivery-route"))
        self.expect("nor for a delivery milestone", None, ids.get("wp-milestone"))

        d = classify(issue(382, kind="Decision", fields={"Decision State": "Decided"},
                           milestone="0.8.1", body="## Agreed Decision\n\nAccepted.\n"))
        ids = {f.obligation.id: f.answer for f in assess(d)}
        self.expect("a decision carrying a milestone is reported", Answer.MISSING,
              ids.get("decision-no-milestone"))

    def test_a_section_includes_its_subheadings(self):
        """a section includes its subheadings"""
        body = """## Test approach

### Functional user tests — Preview

- [x] somebody used it

### Technical tests — Rehearsal

- [x] and measured it

## Deliveries

One.
"""
        i = classify(issue(363, kind="Project", body=body))
        self.expect("content under ### subheadings is part of the ## section",
              True, len(i.section("Test approach")) > 20)
        self.expect("and the next ## heading ends it",
              False, "One." in i.section("Test approach"))
        self.expect("ticks inside a subsection are counted",
              2, i.ticked_in("Test approach"))

    def test_an_obligation_nothing_can_evidence_is_not_checked_never_met(self):
        """an obligation nothing can evidence is 'not checked', never 'met'"""
        ready = classify(issue(1, kind="Requirement",
                               fields={"Stage": "Ready for Project", "Workstream": "W"}))
        ids = {f.obligation.id: f.answer for f in assess(ready)}
        self.expect("a gap row answers not checked", Answer.NOT_CHECKED, ids.get("ready-complete"))

    def test_a_project_owes_effort_and_priority_once_scoping_is_claimed_settle(self):
        """a project owes effort and priority once scoping is claimed settled"""
        # #346: reaching a queue phase asserts scoping is finished. Restored
        # 2026-09-19 -- dropped silently when check-transitions.sh (582fed8) retired
        # in favour of this model, and the live board still shows #71 and #290 (a
        # parent and a work package, both at Q1) missing exactly what #346 found
        # them missing on 2026-09-17, unreported by this model until now.
        at_scope = classify(issue(1, kind="Project",
                                  fields={"Phase": "Scope", "Workstream": "W"}))
        ids = {f.obligation.id: f.answer for f in assess(at_scope)}
        self.expect("Scope is the initial value and is exempt", None, ids.get("project-effort"))
        self.expect("both fields exempt at Scope", None, ids.get("project-priority"))

        in_queue = classify(issue(71, kind="Project",
                                  fields={"Phase": "Q1", "Workstream": "W"}))
        ids = {f.obligation.id: f.answer for f in assess(in_queue)}
        self.expect("reaching the queue with no effort is reported",
              Answer.MISSING, ids.get("project-effort"))
        self.expect("and no priority is reported the same way",
              Answer.MISSING, ids.get("project-priority"))

        scoped_wp = classify(issue(268, parent=71, fields={
            "Phase": "Q1", "Workstream": "W", "Effort": "Low", "Priority": "High"}))
        ids = {f.obligation.id: f.answer for f in assess(scoped_wp)}
        self.expect("a work package with both fields set passes",
              Answer.MET, ids.get("project-effort"))
        self.expect("both", Answer.MET, ids.get("project-priority"))

    def test_a_pull_request_is_not_an_issue_and_must_still_reach_the_model(self):
        """a pull request is not an issue, and must still reach the model"""
        # GraphQL's `issues` connection excludes pull requests, so a snapshot built
        # from it alone contains no PullRequest at all: classify never reaches that
        # branch, both PR obligations apply to nothing, and R1 cannot see a review
        # waiting. Every one of those reads as "nothing to report".
        self.expect("a pull request classifies as one", "PullRequest", pr.kind)
        ids = {f.obligation.id: f.answer for f in assess(pr)}
        self.expect("a linked issue is found", Answer.MET, ids.get("pr-linked"))
        self.expect("both scope headings are found", Answer.MET, ids.get("pr-scope-stated"))
        # The grid says what a pull request owes: a linked issue, the two headings,
        # the review, CI. A workstream is not on it -- a pull request is a change
        # vehicle and its workstream is that of the issue it refs.
        self.expect("a pull request is never asked for a workstream", None, ids.get("workstream"))

        no_ref = classify(issue(390, kind="PullRequest", fields={"PR State": "Approved"},
                                body="Scope of this delivery: things.\n"))
        ids = {f.obligation.id: f.answer for f in assess(no_ref)}
        self.expect("a pull request with no Refs is reported", Answer.MISSING, ids.get("pr-linked"))
        self.expect("and one with neither heading is too", Answer.MISSING, ids.get("pr-scope-stated"))

    def test_pr_state_is_read_with_sync_pr_state_sh_s_ladder_in_its_order(self):
        """PR State is read with sync-pr-state.sh's ladder, in its order"""
        # Two answers to one question is the disagreement this model exists to remove.
        self.expect("draft beats everything, approval included",
              "Drafting", pr_state(True, "APPROVED", 1))
        self.expect("approved", "Approved", pr_state(False, "APPROVED", 0))
        # **Merged and closed are tested before anything else**, as sync-pr-state.sh
        # tests them. Without this rung a closed pull request read as "Drafting" --
        # #393 did, in R2's first run, hours after the board itself said "Closed".
        self.expect("merged beats every other rung", "Merged",
              pr_state(True, "CHANGES_REQUESTED", 3, "MERGED"))
        self.expect("closed does too", "Closed", pr_state(False, "APPROVED", 0, "CLOSED"))
        self.expect("an open one is unaffected", "Approved",
              pr_state(False, "APPROVED", 0, "OPEN"))
        self.expect("changes requested", "Changes requested", pr_state(False, "CHANGES_REQUESTED", 1))
        self.expect("a requested reviewer and no decision is awaiting review",
              "Awaiting review", pr_state(False, None, 1))
        self.expect("no reviewer and no decision is still drafting",
              "Drafting", pr_state(False, None, 0))

    def test_an_age_is_named_for_what_it_is(self):
        """an age is named for what it is"""
        w = Waiting(classify(issue(1, kind="Requirement")), "do it", "checkbox")
        self.expect("no age at all falls back to nothing and reads as today",
              True, "(today)" in w.line)
        dated = _replace(w, days=12.4, dated=True)
        self.expect("a timeline age says waiting", True, "12d waiting" in dated.line)
        guessed = _replace(w, days=12.4, dated=False)
        # `quiet` is the weaker claim: last activity of any kind, which a comment
        # resets. Naming them the same would let the weaker read as the stronger.
        self.expect("a fallback age says quiet, not waiting", True, "12d quiet" in guessed.line)
        self.expect("and never claims to be waiting", False, "waiting" in guessed.line)

    def test_r1_sees_only_what_the_owner_must_do(self):
        """R1 sees only what the owner must do"""
        self.expect("a review waiting is his", "pull request",
              getattr(waiting_on_owner(pr), "source", None))
        self.expect("an approved one is not",
              None, waiting_on_owner(classify(issue(1, kind="PullRequest",
                                                    fields={"PR State": "Approved"}))))
        self.expect("an unanswered decision is his", "decision",
              getattr(waiting_on_owner(classify(issue(1, kind="Decision",
                                                      fields={"Decision State": "Asked"}))),
                      "source", None))
        self.expect("a decided one is not", None,
              waiting_on_owner(classify(issue(1, kind="Decision",
                                              fields={"Decision State": "Decided"}))))
        wp = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                            body="## Functional user tests — Preview\n\n- [ ] click it\n"))
        self.expect("an untested delivery is his", "user testing",
              getattr(waiting_on_owner(wp), "source", None))
        done = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                              body="## Functional user tests — Preview\n\n- [x] clicked\n"))
        self.expect("a tested one is not", None, waiting_on_owner(done))

    def test_the_mirror_what_is_waiting_on_claude(self):
        """the mirror: what is waiting on Claude"""
        live = classify(issue2(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"}))
        self.expect("a delivery at Post-deployment owes a review", "post-deployment",
              getattr(waiting_on_claude(live), "source", None))
        # #310: a Release Check project waits for the next release and owes nobody an
        # action. Without this it nags for a review for ever.
        held = classify(issue2(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"},
                               labels=["Release Check"]))
        self.expect("unless it is waiting for a release", None, waiting_on_claude(held))
        self.expect("an approved pull request is Claude's to merge", "pull request",
              getattr(waiting_on_claude(classify(issue2(
                  1, kind="PullRequest", fields={"PR State": "Approved"}))), "source", None))
        self.expect("one awaiting review is not", None,
              waiting_on_claude(classify(issue2(1, kind="PullRequest",
                                                fields={"PR State": "Awaiting review"}))))
        self.expect("and that one is the owner's", "pull request",
              getattr(waiting_on_owner(classify(issue2(1, kind="PullRequest",
                                                       fields={"PR State": "Awaiting review"}))),
                      "source", None))

    def test_a_review_is_not_due_until_it_has_waited(self):
        """a review is not due until it has waited"""
        # Dropped only once the age is KNOWN. Without a date there is nothing to
        # compare, and guessing "probably old enough" would claim work is owed when
        # nothing says so.
        snap = Snapshot((issue2(1, parent=2, fields={"Phase": "Post-deployment",
                                                     "Route": "x"}),), 0.0, 0.0, 1, False)
        got = whats_waiting(snap, dated=False, who="Claude")
        self.expect("an undated review is kept, not guessed away", 1, len(got))
        self.expect("and the threshold it is waiting for is recorded",
              REVIEW_DUE_DAYS, got[0].due_after)

    def test_every_checkbox_says_whose_move_it_is(self):
        """every checkbox says whose move it is"""
        body = """## Functional user tests — Preview

- [ ] **owner** — click it
- [x] **Claude** — wrote the test

## Technical tests — Rehearsal

- [ ] **Claude** — run the script
- [ ] nobody owns this one
"""
        i = classify(issue(1, parent=2, fields={"Phase": "User testing", "Route": "x"},
                           body=body))
        self.expect("four boxes are found", 4, len(i.boxes))
        self.expect("one is the owner's and unticked", 1, len(i.unticked_for("owner")))
        self.expect("one is Claude's and unticked", 1, len(i.unticked_for("Claude")))
        self.expect("the unlabelled one is counted, not assigned", 1, len(i.unlabelled_boxes))
        self.expect("a ticked box is not waiting", "wrote the test", i.boxes[1].text)
        self.expect("the label is stripped from the text", "click it", i.boxes[0].text)
        ids = {f.obligation.id: f.answer for f in assess(i)}
        self.expect("an unlabelled box is reported", Answer.MISSING, ids.get("boxes-labelled"))

        clean = classify(issue(1, kind="Requirement",
                               body="- [ ] **Claude** — do it\n- [x] **owner** — judged\n"))
        self.expect("a fully labelled body passes", Answer.MET,
              {f.obligation.id: f.answer for f in assess(clean)}.get("boxes-labelled"))
        self.expect("an em dash is not required", 1,
              len(classify(issue(1, body="- [ ] **owner** - hyphen works\n")).unticked_for("owner")))

    def test_a_recurrence_comes_round_again_and_the_date_is_its_only_state(self):
        """a recurrence comes round again, and the date is its only state"""
        # #291 R2: the capacity plan is reviewed on a recurrence rather than when
        # somebody remembers. A job a machine runs is #400's; a review two people do
        # is this, because it has to reach a person and wait for them. Doing the
        # review moves the date on -- there is no store and nothing to reconcile.
        past = due("**Next review due:** 2020-01-01 — **Claude**\n")
        self.expect("a date that has passed is waiting", "recurrence",
              getattr(waiting_on_claude(past), "source", None))
        self.expect("and it is reported as Claude's, not the owner's", None,
              waiting_on_owner(past))
        self.expect("the age is how long it has been overdue", True,
              getattr(waiting_on_claude(past), "age", 0) > 2000)

        future = due("**Next review due:** 2099-01-01 — **Claude**\n")
        self.expect("a date still ahead is not waiting", None, waiting_on_claude(future))

        his = due("Next capacity review due 2020-01-01 (**owner**)\n")
        self.expect("the label decides whose it is", "recurrence",
              getattr(waiting_on_owner(his), "source", None))
        self.expect("so the other side sees nothing", None, waiting_on_claude(his))

        # The phase does not gate it, and that is deliberate: DUE_AT gates checkboxes
        # because a box written at design describes work a later step will do. A date
        # describes nothing -- it is the statement that this comes round again.
        designing = due("**Next review due:** 2020-01-01 — **Claude**\n",
                        **{"Phase": "Design and Test Approach"})
        self.expect("a phase that gates boxes does not gate a date", "recurrence",
              getattr(waiting_on_claude(designing), "source", None))

        # 2026-13-40 is date-shaped and is not a date. Not worth failing a report over.
        self.expect("an impossible date is not a recurrence", 0,
              len(due("Next review due: 2026-13-40\n").recurrences))
        self.expect("an unlabelled one is waiting on nobody", 0,
              len([r for r in due("Next review due: 2020-01-01\n").recurrences
                   if r.who is not None]))

    def test_a_post_deployment_check_is_not_due_before_the_change_reaches_prod(self):
        """a post-deployment check is not due before the change reaches production"""
        # The mirror of the Design-section fix above: DUE_AT opens at Deployment,
        # right for a test-approach box and wrong for one asking whether the benefit
        # arrived in production, which has not happened yet. #399 sat at Deployment,
        # not yet released, and its post-deployment check was already surfacing as
        # waiting on the owner -- he noticed, nothing else would have.
        at_deployment = classify(issue(1, parent=2,
                                       fields={"Phase": "Deployment", "Route": "x"},
                                       body="## Test approach\n\n- [ ] **owner** — run it\n\n"
                                            "## Post-deployment checks against requirements\n\n"
                                            "- [ ] **owner** — the benefit arrived\n"))
        self.expect("a test-approach box is due at Deployment", 1,
              len(due_boxes(at_deployment, "owner")))
        self.expect("but the post-deployment box is not", "run it",
              due_boxes(at_deployment, "owner")[0].text)
        self.expect("so it does not report as waiting either", "checkbox",
              getattr(waiting_on_owner(at_deployment), "source", None))

        at_post = classify(issue(1, parent=2,
                                 fields={"Phase": "Post-deployment", "Route": "x"},
                                 body="## Post-deployment checks against requirements\n\n"
                                      "- [ ] **owner** — the benefit arrived\n"))
        self.expect("at Post-deployment the same box is due", 1,
              len(due_boxes(at_post, "owner")))

        at_closedown = classify(issue(1, parent=2,
                                      fields={"Phase": "Project Closedown", "Route": "x"},
                                      body="## Post-deployment checks against requirements\n\n"
                                           "- [ ] **owner** — the benefit arrived\n"))
        self.expect("and still is at Project Closedown", 1,
              len(due_boxes(at_closedown, "owner")))

    def test_a_delivery_at_closedown_owes_its_lesson_or_says_who_carries_it(self):
        """a delivery at closedown owes its lesson, or says who carries it"""
        # This was a gap: the obligation existed with no evidence function, so #398
        # reached Project Closedown owing lessons learnt and read as complete. The
        # delegation is why it looked hard -- docs/5.1 lets a package point at its
        # parent, so an absent heading is not by itself a finding.
        closing = classify(issue(1, parent=2, fields={"Phase": "Project Closedown", "Route": "x"},
                                 body="nothing to say\n"))
        ids = {f.obligation.id: f.answer for f in assess(closing)}
        self.expect("no lesson and no delegation is a finding", Answer.MISSING,
              ids.get("wp-closedown"))
        learnt = classify(issue(1, parent=2, fields={"Phase": "Project Closedown", "Route": "x"},
                                body="## Lessons learnt\n\nthe check reported sed's status\n"))
        self.expect("a lesson answers it", Answer.MET,
              {f.obligation.id: f.answer for f in assess(learnt)}.get("wp-closedown"))
        delegated = classify(issue(1, parent=2, fields={"Phase": "Project Closedown", "Route": "x"},
                                   body="Delegated to #71\n"))
        self.expect("so does delegating it to the parent", Answer.MET,
              {f.obligation.id: f.answer for f in assess(delegated)}.get("wp-closedown"))
        # The other half, matching parent-closedown: a package that closes with a box
        # outstanding leaves work owned by nobody.
        outstanding = classify(issue(1, parent=2, fields={"Phase": "Project Closedown", "Route": "x"},
                                     body="## Lessons learnt\n\n- [ ] **owner** — still to do\n"))
        self.expect("an unticked box still fails it", Answer.MISSING,
              {f.obligation.id: f.answer for f in assess(outstanding)}.get("wp-closedown"))

    def test_a_box_is_not_waiting_until_it_is_due(self):
        """a box is not waiting until it is due"""
        # Labelling made 126 boxes visible at once. Listing every one of the owner's
        # turns R1 into everything that will ever need him, which is the report that
        # gets skimmed.
        req = classify(issue(1, kind="Requirement", fields={"Stage": "Triage"},
                             body="- [ ] **owner** — future evidence\n"))
        self.expect("a requirement's evidence box is never due", False, boxes_are_due(req))
        self.expect("so it is not reported as waiting", None, waiting_on_owner(req))
        scoped = classify(issue(1, parent=2, fields={"Phase": "Scope", "Route": "x"},
                                body="- [ ] **owner** — a test written early\n"))
        self.expect("a delivery still in Scope is not due", False, boxes_are_due(scoped))
        live = classify(issue(1, parent=2, fields={"Phase": "Post-deployment", "Route": "x"},
                              body="- [ ] **owner** — did the benefit arrive\n"))
        self.expect("one at Post-deployment is", True, boxes_are_due(live))
        self.expect("and it reports as the owner's", "checkbox",
              getattr(waiting_on_owner(live), "source", None))

        # **Design is due in part.** A test-approach box at that step is future
        # evidence and stays quiet; a box under `Design` is a question asked today.
        # #291's two design questions were written on 2026-09-21 and landed in
        # *not yet due* the moment they were written -- the one place a report that
        # answers "what needs you" must not put a question.
        designing = classify(issue(1, parent=2,
                                   fields={"Phase": "Design and Test Approach", "Route": "x"},
                                   body="## Design\n\n- [ ] **owner** — which recurrence\n\n"
                                        "## Test approach\n\n- [ ] **owner** — play a game\n"))
        self.expect("the step as a whole is still not due", False, boxes_are_due(designing))
        self.expect("but the Design box is", 1, len(due_boxes(designing, "owner")))
        self.expect("and the test-approach box is not", "which recurrence",
              due_boxes(designing, "owner")[0].text)
        self.expect("so it reports as the owner's", "checkbox",
              getattr(waiting_on_owner(designing), "source", None))
        # Only projects: a Requirement at no phase at all must not acquire boxes here.
        self.expect("a requirement gains nothing from the section rule", 0,
              len(due_boxes(req, "owner")))

    def test_a_red_main_is_claude_s_and_the_claude_view_says_so(self):
        """a red main is Claude's, and the Claude view says so"""
        # programme.py already said it -- "nothing releases from a red main, and it is
        # Claude's to fix rather than the owner's" -- but in the *status* report. The
        # report that answers what is waiting on Claude was silent about it.
        empty = Snapshot(issues=(), started_at=0.0, finished_at=0.0, pages=1,
                         with_bodies=True)
        _was = _repo.ci_red_on_main
        try:
            _repo.ci_red_on_main = lambda: "failure"
            claude_view, _ = _turn.render(empty, colour=False, who="Claude")
            owner_view, _ = _turn.render(empty, colour=False, who="owner")
            self.expect("the Claude view names it", True, "CI is red on main" in claude_view)
            self.expect("the owner's does not — it is not his to fix", False,
                  "CI is red on main" in owner_view)
            # An absent answer must not read as a failure any more than as a pass.
            _repo.ci_red_on_main = lambda: None
            quiet, _ = _turn.render(empty, colour=False, who="Claude")
            self.expect("a run still pending says nothing", False, "CI is red" in quiet)
        finally:
            _repo.ci_red_on_main = _was


if __name__ == "__main__":
    unittest.main()

