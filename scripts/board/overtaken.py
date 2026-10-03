"""A shipped project still open when the next release went out.

Moved from `verify.sh`'s `check_reviews`, which asked GitHub twice to answer it:
once for every open project at `Post-deployment` or `Project Closedown`, then
once per project for the timeline event that dated it. Both questions the model
already answers -- `classify` gives the kind and step, `step_ages` dates any
field reaching any value.

**Dated from entering `Post-deployment`, not from the phase it is in now.** That
is when it shipped, and it is the clock that matters: a project that wrote its
review promptly and then sat unclosed for a month has still been open a month.
`verify.sh` had that reasoning and it is kept.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .model import Issue, ParentProject, StandaloneProject, WorkPackage

# Both phases a *shipped* project can sit in and rot: it still owes its review,
# or it owes only its closing.
SHIPPED_STEPS = ("Post-deployment", "Project Closedown")
PROJECTS = (ParentProject, StandaloneProject, WorkPackage)


@dataclass(frozen=True)
class Overtaken:
    number: int
    title: str
    step: str


def candidates(issues: Sequence[Issue]) -> tuple[Issue, ...]:
    """Projects that have shipped and not closed, so are worth dating."""
    return tuple(i for i in issues
                 if isinstance(i, PROJECTS) and i.step in SHIPPED_STEPS)


def check(issues: Sequence[Issue], shipped_at: dict[int, float],
          last_release: float | None) -> tuple[Overtaken, ...]:
    """Which of them entered `Post-deployment` before the last release.

    `last_release` of None means no release has happened, so nothing can have
    been overtaken -- not that everything has.
    """
    if last_release is None:
        return ()
    out = []
    for issue in candidates(issues):
        when = shipped_at.get(issue.number)
        # No date is not an overtaking. A project whose timeline does not carry
        # the event -- set before the field existed, or moved by a migration --
        # is unknown, and unknown must not read as late.
        if when is None:
            continue
        if when < last_release:
            out.append(Overtaken(issue.number, issue.title, issue.step or ""))
    return tuple(out)


def render(found: Sequence[Overtaken], colour: bool = True) -> str:
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    red = (lambda s: f"\033[31m{s}\033[0m") if colour else (lambda s: s)
    green = (lambda s: f"\033[32m{s}\033[0m") if colour else (lambda s: s)

    out = [f"{bold('OVERTAKEN')}  {dim('shipped, and still open when the next release went')}"]
    if not found:
        out.append(f"  {green('ok')} {dim('nothing shipped past a project still open from an earlier release')}")
        return "\n".join(out)
    for o in found:
        out.append(f"  {red('!!')} {bold(f'#{o.number}')} {dim(f'at {o.step}')}  {o.title[:58]}")
    return "\n".join(out)
