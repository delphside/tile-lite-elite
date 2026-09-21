"""The board's issues, as one class per type.

Designed in `docs/changes/workstreams/delivery-tooling/383-one-board-model/`.
The rule this exists to enforce: **a fact is derived in exactly one place, is
named there, and every consumer imports it.** Nine scripts each re-derive the
same few concepts today, and the cost is not duplication but disagreement —
two pictures of "is this built" disagreed about parentage (#370, #375), and
two of "does this owe a route" disagreed about parents (#297).

No I/O happens here. `sources.py` fetches; this interprets.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from typing import Iterator, Mapping, Sequence

# --------------------------------------------------------------------------
# what a source hands over
# --------------------------------------------------------------------------


OWNER, CLAUDE = "owner", "Claude"

# `- [ ] **owner** — run the six browser tests`
#
# Owner, 2026-09-18: *"Label Checkboxes consistently as Claude or owner so the
# tools can differentiate."* Before this, every box looked alike, so nothing
# could tell a task waiting on the owner from one waiting on Claude -- which is
# why R1 could not derive its fourth source and said so under every run.
#
# The label is on the box, not inferred from the heading it sits under: a box
# moved to another section keeps its owner, and a reader sees whose it is
# without scrolling up.
_BOX = re.compile(
    r"^[ \t]*[-*][ \t]*\[([ xX])\][ \t]*"
    r"(?:\*\*(owner|Claude)\*\*[ \t]*[\u2014\u2013-][ \t]*)?"
    r"(.*)$",
    re.M | re.IGNORECASE)


# `**Next review due:** 2026-12-21 — **Claude**`
#
# **A recurrence, and the only state it keeps is the date.** #291 R2: the
# capacity plan is reviewed on a recurrence rather than when somebody
# remembers. A job a machine runs is a scheduled job and belongs to #400; a
# review two people do is this, because it has to reach a person and wait for
# them. Owner, 2026-09-21: *"Reviewing the capacity plan requires Claude to
# update and Steve to review, so an issue date makes more sense."*
#
# Doing the review moves the date on, which is what makes it recur. There is
# no store, no last-run file and nothing to reconcile -- the same reasoning
# #166 gives for the scheduler: rederive, and a restart is automatically
# correct.
#
# Labelled like a checkbox and for the same reason: the label is on the line,
# so a reader sees whose it is without scrolling up, and an unlabelled one is
# waiting on nobody.
_DUE = re.compile(
    r"^[ \t]*\**[ \t]*Next[ \t]+[^:\n]{0,40}?due[ \t]*\**[ \t]*:?[ \t]*\**[ \t]*"
    r"(\d{4}-\d{2}-\d{2})"
    r"(?:[^\n]*?\*\*(owner|Claude)\*\*)?",
    re.M | re.IGNORECASE)


@dataclass(frozen=True)
class Recurring:
    """Something that falls due again every time it is done."""

    due: date
    who: str | None
    text: str

    def overdue_by(self, today: date) -> int:
        """Days past due. Negative means it has not come round yet."""
        return (today - self.due).days


@dataclass(frozen=True)
class Box:
    """One checkbox, and whose move it is."""

    ticked: bool
    who: str | None
    text: str


@dataclass(frozen=True)
class RawSubIssue:
    number: int
    issue_type: str | None


@dataclass(frozen=True)
class RawIssue:
    """Exactly what GitHub returned, uninterpreted."""

    number: int
    title: str
    state: str
    body: str
    issue_type: str | None
    fields: Mapping[str, str]
    sub_issues: Sequence[RawSubIssue]
    parent: int | None
    milestone: str | None
    labels: frozenset[str]
    # GitHub's own issue dependencies. The board cannot show them, which is
    # why the roadmap diagram exists — owner, 2026-09-18.
    blocked_by: frozenset[int] = frozenset()
    blocks: frozenset[int] = frozenset()
    # Reports ask "for how long"; gates only ask "is it true now". These are
    # the cheapest answer GitHub gives, and `updated_at` is last activity of
    # any kind -- NOT when the field reached its current value. R1 says so
    # rather than implying a precision it does not have.
    created_at: str | None = None
    updated_at: str | None = None
    # Needed by R2, which asks what *changed* in a window: an issue closed in
    # silence produces no comment at all, so a comment listing never reveals it.
    closed_at: str | None = None


# --------------------------------------------------------------------------
# the issues
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Issue:
    """What every issue has. `step` is what the obligations grid is indexed by."""

    raw: RawIssue
    type_was_defaulted: bool = False
    stage_was_defaulted: bool = False

    # -- identity ----------------------------------------------------------
    @property
    def number(self) -> int:
        return self.raw.number

    @property
    def title(self) -> str:
        return self.raw.title

    @property
    def state(self) -> str:
        return self.raw.state

    @property
    def body(self) -> str:
        return self.raw.body or ""

    @property
    def kind(self) -> str:
        return type(self).__name__

    # -- fields, always by name --------------------------------------------
    def field(self, name: str) -> str | None:
        """A field's value by NAME. Option ids never leave `sources.py`."""
        return self.raw.fields.get(name)

    @property
    def step(self) -> str | None:
        """The lifecycle step this issue is at. Overridden per type."""
        return None

    @property
    def step_field(self) -> str:
        return "-"

    # -- body reading ------------------------------------------------------
    def has_heading(self, text: str) -> bool:
        """A markdown heading whose text matches, at any level.

        Matched case-insensitively and ignoring trailing punctuation, because
        `## Test approach` and `## Test Approach:` are the same heading to a
        reader and differ only to a grep.
        """
        wanted = text.strip().lower().rstrip(":")
        for line in self.body.splitlines():
            if not line.lstrip().startswith("#"):
                continue
            got = line.lstrip("#").strip().lower().rstrip(":")
            if got == wanted or got.startswith(wanted + " "):
                return True
        return False

    def section(self, heading: str) -> str:
        """The text under a heading, including its subheadings.

        Stops at the next heading of the SAME OR HIGHER level, not at the next
        heading of any level. The documented shape of a test approach is
        `## Test approach` with `### Functional user tests` and
        `### Technical tests` beneath it, so stopping at any heading reported
        a fully written section as empty — #363 read as having no test
        approach when it has one under its subheadings.
        """
        wanted = heading.strip().lower().rstrip(":")
        out: list[str] = []
        depth: int | None = None
        for line in self.body.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("#"):
                level = len(stripped) - len(stripped.lstrip("#"))
                got = stripped.lstrip("#").strip().lower().rstrip(":")
                if depth is not None:
                    if level <= depth:
                        break
                    out.append(line)          # a subheading is part of it
                    continue
                if got == wanted or got.startswith(wanted + " "):
                    depth = level
                continue
            if depth is not None:
                out.append(line)
        return "\n".join(out).strip()

    # -- checkboxes --------------------------------------------------------
    @property
    def boxes(self) -> list[Box]:
        out = []
        for mark, who, text in _BOX.findall(self.body):
            label = None
            if who:
                label = OWNER if who.lower() == "owner" else CLAUDE
            out.append(Box(mark.lower() == "x", label, text.strip()))
        return out

    @property
    def recurrences(self) -> list[Recurring]:
        out = []
        for line in self.body.splitlines():
            m = _DUE.search(line)
            if not m:
                continue
            try:
                when = date.fromisoformat(m.group(1))
            except ValueError:
                # A date-shaped string that is not a date -- 2026-13-40. Not a
                # recurrence, and not worth failing a report over.
                continue
            who = m.group(2)
            label = None
            if who:
                label = OWNER if who.lower() == "owner" else CLAUDE
            # Asterisks stripped throughout, not just at the ends: the label
            # sits mid-line, so `.strip("*")` leaves `review due:** 2026-…`.
            out.append(Recurring(when, label,
                                 line.replace("*", "").strip(" -\u2014\t")))
        return out

    def boxes_in(self, heading: str) -> list[Box]:
        section = Issue(RawIssue(0, "", "", self.section(heading), None, {},
                                 (), None, None, frozenset()))
        return section.boxes

    def unticked_for(self, who: str) -> list[Box]:
        return [b for b in self.boxes if not b.ticked and b.who == who]

    @property
    def unlabelled_boxes(self) -> list[Box]:
        """Boxes that say nothing about whose move it is.

        Reported rather than assumed: guessing from the heading would be the
        same inference the label exists to replace, and a box nobody owns is
        how work waits on nobody at all.
        """
        return [b for b in self.boxes if b.who is None]

    @property
    def unticked_boxes(self) -> int:
        """Unticked boxes anywhere in the body.

        Only correct where the obligation really is about the whole issue —
        closedown, which owes no unticked boxes at all. For anything scoped to
        a section use `unticked_in`: counting globally made #252 report its
        post-deployment checks as unanswered when they were answered and its
        *test approach* boxes were the unticked ones. Naming the wrong thing
        to fix is the defect this model exists to stop.
        """
        return len(re.findall(r"^\s*[-*]\s*\[ \]", self.body, re.M))

    def unticked_in(self, heading: str) -> int:
        return len(re.findall(r"^\s*[-*]\s*\[ \]", self.section(heading), re.M))

    def unanswered_rows_in(self, heading: str) -> int:
        """Table rows under a heading whose last cell is empty.

        **Post-deployment checks are a table, not a checklist**, so counting
        boxes says a section full of blank answers is complete. #374 reported
        `complete, 0 not checked` on 2026-09-19 with R1 and R2 both unanswered;
        the rule that caught it (#346 R4) did not survive `check-transitions.sh`
        retiring into this model.

        **Empty, rather than not one of `passed`/`cannot be tested`/`failed`.**
        The bash rule required those three words and so flagged rows carrying a
        considered answer in other words. A blank cell is unambiguous; judging
        prose is a person's job, and a check that cries wolf gets ignored rather
        than fixed.
        """
        rows = 0
        seen_header = False
        for line in self.section(heading).splitlines():
            stripped = line.strip()
            if not stripped.startswith("|"):
                continue
            if re.match(r"^\|[\s:-]+\|", stripped):      # the --- separator
                continue
            if not seen_header:                            # the header row
                seen_header = True
                continue
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            if cells and not cells[-1]:
                rows += 1
        return rows

    def ticked_in(self, heading: str) -> int:
        return len(re.findall(r"^\s*[-*]\s*\[[xX]\]", self.section(heading), re.M))

    @property
    def ticked_boxes(self) -> int:
        return len(re.findall(r"^\s*[-*]\s*\[[xX]\]", self.body, re.M))

    # -- shape -------------------------------------------------------------
    @property
    def sub_issues(self) -> Sequence[RawSubIssue]:
        return self.raw.sub_issues

    @property
    def parent(self) -> int | None:
        return self.raw.parent

    @property
    def labels(self) -> frozenset[str]:
        return self.raw.labels

    # -- sequencing --------------------------------------------------------
    @property
    def blocked_by(self) -> frozenset[int]:
        """What must finish first, as GitHub records it.

        The project board has no column for this, so it is invisible until
        something draws it: `scripts/roadmap-diagram.py` is that something.
        """
        return self.raw.blocked_by

    @property
    def blocks(self) -> frozenset[int]:
        return self.raw.blocks

    # -- age ---------------------------------------------------------------
    @property
    def quiet_days(self) -> float | None:
        """Days since anything at all happened on this issue.

        A floor on how long something has been waiting, not a measure of it:
        a comment that changed nothing resets it. Named `quiet_days` rather
        than `waiting_days` so no consumer can read it as the latter.
        """
        if not self.raw.updated_at:
            return None
        stamp = datetime.fromisoformat(self.raw.updated_at.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - stamp).total_seconds() / 86400


@dataclass(frozen=True)
class Requirement(Issue):
    """A request for a change. Its journey is `Stage`."""

    @property
    def step(self) -> str | None:
        # Owner, 2026-09-18: an unset Stage is Triage. A row every rule skips
        # is a row nothing enforces, which is the untyped defect (#361) in
        # different clothes.
        return self.field("Stage") or "Triage"

    @property
    def step_field(self) -> str:
        return "Stage"


@dataclass(frozen=True)
class Project(Issue):
    """A bounded piece of work. Its journey is `Phase`."""

    @property
    def step(self) -> str | None:
        return self.field("Phase")

    @property
    def step_field(self) -> str:
        return "Phase"


@dataclass(frozen=True)
class ParentProject(Project):
    """Owns requirements, design and documents. Makes no delivery itself.

    Carries no Route and no milestone: both answer how a change reaches its
    users, and a parent has no delivery role. Its work packages carry one
    each. See #297 — a report asked a parent for a route and named the wrong
    thing to fix, and two parents were given one to silence it.
    """

    @property
    def work_packages(self) -> list[int]:
        return [s.number for s in self.sub_issues if s.issue_type == "Project"]

    @property
    def folded_requirements(self) -> list[int]:
        return [s.number for s in self.sub_issues if s.issue_type == "Requirement"]


@dataclass(frozen=True)
class WorkPackage(Project):
    """One delivery of a parent project. Carries a Route and a milestone."""

    @property
    def route(self) -> str | None:
        return self.field("Route")

    @property
    def milestone(self) -> str | None:
        return self.raw.milestone


@dataclass(frozen=True)
class StandaloneProject(Project):
    """One delivery, with no work packages under it. Carries both."""

    @property
    def route(self) -> str | None:
        return self.field("Route")

    @property
    def milestone(self) -> str | None:
        return self.raw.milestone


@dataclass(frozen=True)
class Decision(Issue):
    """A question and its answer. Its journey is `Decision State`."""

    @property
    def step(self) -> str | None:
        return self.field("Decision State")

    @property
    def step_field(self) -> str:
        return "Decision State"

    @property
    def agreed(self) -> str:
        return self.section("Agreed Decision")


@dataclass(frozen=True)
class PullRequest(Issue):
    """The review surface. Its journey is `PR State`.

    A pull request is an issue in GitHub and is modelled as one here, so the
    review surface is inside the model rather than beside it.
    """

    @property
    def step(self) -> str | None:
        return self.field("PR State")

    @property
    def step_field(self) -> str:
        return "PR State"


# --------------------------------------------------------------------------
# classification: the one place an issue's kind is decided
# --------------------------------------------------------------------------


def classify(raw: RawIssue) -> Issue:
    """Turn a raw issue into the class that knows what it owes.

    The parent test is the narrow one and is the part that breaks: **a parent
    is a project whose sub-issues include projects**, not a project with any
    sub-issues. A project carries folded requirements as sub-issues routinely
    and is still one delivery owing one route — #214 has two work packages and
    two folded requirements, and counting sub-issues rather than project
    sub-issues misread it.
    """
    match raw.issue_type:
        case "Decision":
            return Decision(raw)
        case "PullRequest":
            return PullRequest(raw)
        case "Project":
            if any(s.issue_type == "Project" for s in raw.sub_issues):
                return ParentProject(raw)
            if raw.parent is not None:
                return WorkPackage(raw)
            return StandaloneProject(raw)
        case "Requirement":
            return Requirement(
                raw, stage_was_defaulted=raw.fields.get("Stage") is None
            )
        case _:
            # Owner, 2026-09-18: untyped becomes a Requirement. There is no
            # Untyped class — a class owing nothing is skipped by every rule
            # keyed on type, which is #361 restated rather than fixed.
            return Requirement(
                raw,
                type_was_defaulted=True,
                stage_was_defaulted=raw.fields.get("Stage") is None,
            )


def classify_all(raws: Iterator[RawIssue]) -> list[Issue]:
    return [classify(r) for r in raws]
