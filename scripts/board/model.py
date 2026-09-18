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
from typing import Iterator, Mapping, Sequence

# --------------------------------------------------------------------------
# what a source hands over
# --------------------------------------------------------------------------


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
