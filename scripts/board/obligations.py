"""The grid: what each issue type owes at each lifecycle step.

This is `docs/changes/workstreams/delivery-tooling/383-one-board-model/obligations.md`
as data rather than as prose. The document is the argument; this is the
requirement, and R4 is it rendered.

**A row with no `check` answers `not checked`, never `met`.** An obligation
nothing can evidence must not read as satisfied — that is how sixteen of these
have been invisible, and how an untyped issue used to pass everything by
being exempt from it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Callable

from .model import (
    Decision,
    Issue,
    ParentProject,
    PullRequest,
    Requirement,
    StandaloneProject,
    WorkPackage,
)

ANY_STEP = ()


class Answer(Enum):
    MET = "met"
    MISSING = "missing"
    NOT_CHECKED = "not checked"


@dataclass(frozen=True)
class Obligation:
    id: str
    applies_to: tuple[type, ...]
    steps: tuple[str, ...]
    what: str
    why: str
    check: Callable[[Issue], bool] | None = None

    def relevant_to(self, issue: Issue) -> bool:
        if not isinstance(issue, self.applies_to):
            return False
        return not self.steps or (issue.step in self.steps)

    def answer(self, issue: Issue) -> Answer:
        if self.check is None:
            return Answer.NOT_CHECKED
        return Answer.MET if self.check(issue) else Answer.MISSING


# --------------------------------------------------------------------------
# helpers the rows share, so a test is written once
# --------------------------------------------------------------------------


def fields_set(*names: str) -> Callable[[Issue], bool]:
    return lambda i: all(i.field(n) for n in names)


def has_headings(*headings: str) -> Callable[[Issue], bool]:
    return lambda i: all(i.has_heading(h) for h in headings)


def headings_answered(*headings: str) -> Callable[[Issue], bool]:
    """Each heading exists and has something under it — content or a pointer.

    Owner, 2026-09-18: *"Both, but one will point at the other. All docs will
    be stored in the parent project folder, or in the bodies... both parent
    and work package describe where it is."*

    So a parent and its work package both owe a test approach, and either may
    satisfy it by naming where the other holds it. What neither may do is stay
    silent: the obligation is to say where it is, and an absent heading says
    nothing. That is why this is stricter than checking the heading exists —
    an empty heading is the same silence with a title on it.

    `CLAUDE.md` adds *"the content or a link to the design document that holds
    it, never both"*. The "never both" half is not checked: telling a summary
    from a duplicate needs judgement, and a check that guesses at it would cry
    wolf.
    """
    def check(issue: Issue) -> bool:
        return all(
            issue.has_heading(h) and _has_substance(issue.section(h))
            for h in headings
        )

    return check


def _has_substance(body: str) -> bool:
    # a table skeleton, a placeholder, or nothing at all is not an answer
    stripped = re.sub(r"[|\-\s]", "", body).lower()
    return bool(stripped) and stripped not in {"none", "n/a", "tbd", "tbc"}


def section_has_text(heading: str) -> Callable[[Issue], bool]:
    def check(issue: Issue) -> bool:
        body = issue.section(heading)
        # a heading with only a table skeleton or "none" under it is empty
        stripped = re.sub(r"[|\-\s]", "", body).lower()
        return bool(stripped) and stripped not in {"none", "n/a", "tbd"}

    return check


def never(_: Issue) -> bool:
    return False


PROJECTS = (ParentProject, WorkPackage, StandaloneProject)
DELIVERING = (WorkPackage, StandaloneProject)
BUILD_PHASES = ("Development", "User testing", "Deployment")


# --------------------------------------------------------------------------
# the grid
# --------------------------------------------------------------------------

OBLIGATIONS: tuple[Obligation, ...] = (
    # ---- every issue, whatever it is ------------------------------------
    Obligation(
        "type-set", (Issue,), ANY_STEP,
        "an issue type",
        "every rule is keyed on type, so an untyped issue is skipped by all "
        "of them and reads as compliant — #361",
        lambda i: not i.type_was_defaulted,
    ),
    Obligation(
        "stage-set", (Requirement,), ANY_STEP,
        "a Stage",
        "an unset stage is a row every rule skips",
        lambda i: not i.stage_was_defaulted,
    ),
    Obligation(
        # NOT PullRequest. The grid lists what a pull request owes -- a linked
        # issue, the two headings, the review, CI -- and a workstream is not on
        # it: a pull request is a change vehicle, and its workstream is the
        # workstream of the issue it refs. Asking one for a field it does not
        # carry is the defect this model exists to remove, and it appeared here
        # the moment pull requests started reaching the model.
        "workstream", (Requirement, ParentProject, WorkPackage,
                       StandaloneProject, Decision), ANY_STEP,
        "a workstream",
        "unset is the triage queue, so an unset workstream is untriaged",
        lambda i: bool(i.field("Workstream")),
    ),

    Obligation(
        "boxes-labelled", (Issue,), ANY_STEP,
        "every checkbox labelled **owner** or **Claude**",
        "an unlabelled box is waiting on nobody: R1 cannot tell a task the "
        "owner must do from one Claude must, and 126 of them accumulated "
        "before anything could say so — owner, 2026-09-18",
        lambda i: not i.unlabelled_boxes,
    ),

    # ---- Requirement, by Stage ------------------------------------------
    Obligation(
        "triage-minimum", (Requirement,), ("Triage",),
        "workstream, type of change and priority",
        "the minimum that makes a requirement placeable",
        fields_set("Workstream", "Type of change", "Priority"),
    ),
    Obligation(
        "scoped-effort", (Requirement,), ("Scope, Options and Dependencies",),
        "effort",
        "size known before it can be queued",
        fields_set("Effort"),
    ),
    Obligation(
        "on-hold-reason", (Requirement,), ("On Hold",),
        "something named under dependencies",
        "a stall names something actionable, or it is invisible",
        section_has_text("Dependencies"),
    ),
    Obligation(
        "ready-complete", (Requirement,),
        ("Ready for Project",),
        "scope, the option chosen, effort, and nothing unresolved",
        "it can be planned without re-reading it",
        None,  # gap: "nothing unresolved" has no evidence yet
    ),
    Obligation(
        "candidate-grouped", (Requirement,),
        ("Candidate Project 1", "Candidate Project 2", "Candidate Project 3"),
        "the same candidate number as its group, and a known route",
        "the candidate stages check nothing today",
        None,  # gap
    ),

    # ---- Parent project, by Phase ---------------------------------------
    Obligation(
        "parent-scope-headings", (ParentProject,), ("Scope",),
        "`## Requirements` and `## Design`, each holding content or a pointer",
        "what the project does, and which technical option",
        headings_answered("Requirements", "Design"),
    ),
    Obligation(
        "parent-no-route", (ParentProject,), ANY_STEP,
        "no Route",
        "a parent has no delivery role; its work packages carry one each — #297",
        lambda i: not i.field("Route"),
    ),
    Obligation(
        "parent-not-building", (ParentProject,), BUILD_PHASES,
        "a parent must not be at a build phase",
        "oversight is a design role; the work packages build",
        never,
    ),
    Obligation(
        "parent-design-testable", (ParentProject,), ("Design and Test Approach",),
        "`## Test approach`, `## Impacted artefacts` and `## Deliveries`, "
        "each holding the content or saying where it is",
        "a parent and its packages both owe these, and either may point at "
        "the other — but neither may stay silent",
        headings_answered("Test approach", "Impacted artefacts", "Deliveries"),
    ),
    Obligation(
        "parent-closedown", (ParentProject,), ("Project Closedown",),
        "lessons learnt, no unticked boxes, every child closed",
        "the lesson is captured while it is still remembered",
        lambda i: i.has_heading("Lessons learnt") and i.unticked_boxes == 0,
    ),

    # ---- Work package and standalone, by Phase --------------------------
    Obligation(
        "delivery-route", DELIVERING, ANY_STEP,
        "a Route",
        "something must be able to say whether this reaches users",
        lambda i: bool(i.field("Route")),
    ),
    Obligation(
        "wp-design-testable", DELIVERING, ("Design and Test Approach",),
        "a test approach and impacted artefacts, held here or pointed at",
        "a delivery is testable before it is built; the parent may hold the "
        "detail, but this says where",
        headings_answered("Test approach", "Impacted artefacts"),
    ),
    Obligation(
        "wp-user-tested", DELIVERING, ("User testing",),
        "Preview boxes ticked or answered",
        "somebody has used it",
        lambda i: i.ticked_in("Functional user tests — Preview") > 0
                  or i.unticked_in("Functional user tests — Preview") == 0,
    ),
    Obligation(
        "wp-milestone", DELIVERING, ("Deployment", "Post-deployment"),
        "a milestone",
        "a delivery made at one point in time is placed in the sequence",
        lambda i: bool(i.milestone),
    ),
    Obligation(
        "wp-built", DELIVERING, ("Deployment",),
        "commits naming it",
        "a milestone's issues are backed by commits",
        None,  # gap here: needs git, which this report does not yet read
    ),
    Obligation(
        "wp-post-deployment", DELIVERING, ("Post-deployment",),
        "one check per requirement, each answered",
        "it did what it was for",
        # Scoped to its own section. Counting boxes across the whole body
        # made #252 report answered checks as unanswered, because its Test
        # approach boxes were the unticked ones.
        lambda i: (i.has_heading("Post-deployment checks")
                   and i.unticked_in("Post-deployment checks against requirements") == 0
                   and i.unticked_in("Post-deployment checks") == 0),
    ),
    Obligation(
        "wp-closedown", DELIVERING, ("Project Closedown",),
        "lessons learnt, or a statement that the parent carries them",
        "a delivery's lesson is captured or delegated",
        None,  # gap
    ),

    # ---- Decision, by Decision State ------------------------------------
    Obligation(
        "decision-question", (Decision,), ("Asked",),
        "a question, options, and what turns on it",
        "the question is answerable as put",
        None,  # gap
    ),
    Obligation(
        "decision-no-milestone", (Decision,), ANY_STEP,
        "no milestone",
        "a decision is not a change vehicle: it routes work and ships nothing, "
        "so it takes no semver and no letter milestone — CLAUDE.md",
        lambda i: i.raw.milestone is None,
    ),
    Obligation(
        "decision-parent", (Decision,), ANY_STEP,
        "a parent, where a project carries out what it decided",
        "a decision may be a child of the project that does the delivery — "
        "owner, 2026-09-18",
        None,  # gap: a decision need not have one, so absence is not a defect
    ),
    Obligation(
        "decision-agreed", (Decision,), ("Decided", "Actioned"),
        "an `Agreed Decision` heading with an answer under it",
        "it is settled, and the answer is where it will be found",
        lambda i: bool(i.agreed.strip()),
    ),
    Obligation(
        "decision-actioned", (Decision,), ("Actioned",),
        "applied in the same commit that marked it answered, or an issue raised",
        "nothing checks that an Actioned decision changed anything",
        None,  # gap
    ),

    # ---- Pull request, by PR State --------------------------------------
    Obligation(
        "pr-linked", (PullRequest,), ANY_STEP,
        "a linked issue — `Refs #N` or `Closes #N`",
        "a change with no issue has no requirement",
        lambda i: bool(re.search(r"\b(Refs|Closes) #\d+", i.body)),
    ),
    Obligation(
        "pr-scope-stated", (PullRequest,),
        ("Awaiting review", "Approved", "Changes requested"),
        "what is being requested, and what is deliberately left out",
        "the body is the review surface — owner, 2026-09-17",
        has_headings("What is being requested", "What is deliberately left out"),
    ),
)


@dataclass(frozen=True)
class Finding:
    obligation: Obligation
    answer: Answer


def assess(issue: Issue) -> list[Finding]:
    """Every obligation relevant to this issue, answered."""
    return [
        Finding(o, o.answer(issue))
        for o in OBLIGATIONS
        if o.relevant_to(issue)
    ]
