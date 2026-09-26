"""What a merge into `main` moves on the board.

When a project branch fast-forwards into `main`, its work package has left
testing: the Phase table in CLAUDE.md puts a merged image change in
*Deployment* (it waits for the release that ships it) and a merged repository
change past it (the merge *was* its deployment). Owner, 2026-09-26: *"We need
to indicate when a wp has moved beyond testing and been merged into main."*

Called from `.githooks/post-merge` by way of `scripts/board-merged.py`. The
decision is here, apart from git and GitHub, so it can be tested on its own.
"""

from __future__ import annotations

import re
from typing import Iterable, Mapping

from .model import Issue, StandaloneProject, WorkPackage

# Phases a merge moves on from. Anything later is left alone: a merge never
# moves a Phase backwards, and one already past it has been moved by hand.
BEFORE_MERGE = ("Development", "User testing")

_REFS = re.compile(r"\b(?:Refs|Closes|Fixes)\s+#(\d+)", re.I)
_LEAD = re.compile(r"^#(\d+)\b")
_BRANCH = re.compile(r"^(\d+)-")


def named(branch: str, pr_title: str = "", pr_body: str = "") -> list[int]:
    """Every issue the merge could be delivering.

    **The pull request first.** A branch cut before its project was split
    names the parent -- `400-scheduler-mechanism` carried Scheduler core
    (#414) -- while its pull request names the package. The branch's own
    number is kept too, for a branch merged with no pull request.
    """
    found = [int(n) for n in _REFS.findall(pr_body)]
    m = _LEAD.match(pr_title)
    if m:
        found.append(int(m.group(1)))
    m = _BRANCH.match(branch)
    if m:
        found.append(int(m.group(1)))
    return sorted(set(found))


def next_phase(issue: Issue) -> str | None:
    """Where a merge takes this issue, or None if it takes it nowhere.

    Only a delivery has a Phase that a merge completes: a parent does not
    deliver, and a requirement has no Phase.
    """
    if not isinstance(issue, (WorkPackage, StandaloneProject)):
        return None
    if issue.state != "OPEN" or issue.field("Phase") not in BEFORE_MERGE:
        return None
    route = issue.field("Route")
    if route == "Production Release":
        return "Deployment"
    if route == "Repository Change":
        return "Post-deployment"
    return None


def moves(candidates: Iterable[int], issues: Mapping[int, Issue]) -> list[tuple[int, str, str]]:
    """(number, from, to) for each candidate a merge moves on."""
    out = []
    for n in candidates:
        issue = issues.get(n)
        if issue is None:
            continue
        to = next_phase(issue)
        if to:
            out.append((n, issue.field("Phase") or "", to))
    return out
