"""What a milestone still owes before it ships.

Moved from `verify.sh`'s `check_approach`. It asked GitHub for the milestone's
open projects, then for each one's body, then for its sub-issues to tell a
parent from a package -- three questions the model answers from one snapshot.

**A release question, not a per-issue one.** `board-check.py`'s obligations ask
whether *this* delivery owes a test approach at *its* step. This asks whether
the tests the projects in *this release* said they would run have been run, which
is the question a person has before deploying and is scoped by milestone.

**A parent owes nothing here.** Its packages own the test approach -- D51 -- so
naming it would be a finding nobody can clear.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .model import Issue, ParentProject, StandaloneProject, WorkPackage

DELIVERING = (StandaloneProject, WorkPackage)

# Both halves, as the documents name them. `verify.sh` matched on the substring
# so a project writing either the long or the short form was read either way,
# and that latitude is kept: the skill says to write "None." rather than remove
# a heading, and both spellings are in use.
PREVIEW = "Functional user tests"
REHEARSAL = "Technical tests"


@dataclass(frozen=True)
class Outstanding:
    number: int
    title: str
    preview: int
    rehearsal: int
    missing_headings: bool


def outstanding(issues: Sequence[Issue], milestone: str) -> tuple[Outstanding, ...]:
    """Projects in `milestone` with tests they said they would run, unrun.

    A parent is skipped rather than reported. A project with neither heading is
    reported with `missing_headings`, because a delivery that never said what it
    would test is a different fault from one that said and has not.
    """
    out = []
    for issue in issues:
        # Type before milestone: a Decision carries no milestone attribute at
        # all, so asking it first is an AttributeError rather than a mismatch.
        if isinstance(issue, ParentProject):
            continue
        if not isinstance(issue, DELIVERING):
            continue
        if issue.milestone != milestone:
            continue
        preview_un = issue.unticked_in(PREVIEW)
        rehearsal_un = issue.unticked_in(REHEARSAL)
        has_either = issue.has_heading(PREVIEW) or issue.has_heading(REHEARSAL)
        if not has_either:
            out.append(Outstanding(issue.number, issue.title, 0, 0, True))
        elif preview_un or rehearsal_un:
            out.append(Outstanding(issue.number, issue.title,
                                   preview_un, rehearsal_un, False))
    return tuple(out)


def render(found: Sequence[Outstanding], milestone: str,
           colour: bool = True) -> str:
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    red = (lambda s: f"\033[31m{s}\033[0m") if colour else (lambda s: s)
    green = (lambda s: f"\033[32m{s}\033[0m") if colour else (lambda s: s)

    out = [f"{bold('TESTS PROMISED')}  {dim(f'milestone {milestone}')}"]
    if not found:
        out.append(f"  {green('ok')} {dim('nothing outstanding')}")
        return "\n".join(out)
    for o in found:
        if o.missing_headings:
            out.append(f"  {red('!!')} {bold(f'#{o.number}')} {o.title[:46]}  "
                       f"{dim('no test approach headings')}")
        else:
            out.append(f"  {red('!!')} {bold(f'#{o.number}')} {o.title[:46]}  "
                       f"{dim(f'{o.preview} on Preview, {o.rehearsal} on Rehearsal')}")
    return "\n".join(out)
