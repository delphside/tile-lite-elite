"""R9 — a branch is checked against the project it names.

Folded in from #342. `.githooks/commit-msg` compares the branch name against the
`Refs`/`Closes` trailer — **two local strings** — so it can say they agree and
never whether what they agree on is real. Owner, 2026-09-06: *"We have found
before that it is easy to go wrong with branches. We need to track these
relationships and check them."*

**Branches are the model's third source.** It reads issues and commits; this
adds the one neither covers, which is why #342 belonged here rather than
standing alone — the objection that branches are a different seam was the work,
not a reason against it.

The rule is `docs/3.6` §2.12: a branch is created when its project starts and
deleted when the project is **live and closed**. So the two things worth saying
are that the branch names something real, and that it has not outlived it.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Mapping, Sequence

from .model import RawIssue

# `214-build-once`, `290-dioxus-07`, and the older `issue-` form.
_NAMED = re.compile(r"^(?:issue-)?(\d+)-")


def named_numbers(branches, protected=("main",)) -> tuple[int, ...]:
    """The issue numbers these branch names claim, ignoring the rest.

    Lets a caller fetch only what it needs to answer, rather than the board.
    """
    out = []
    for branch in branches:
        if branch in protected or branch.startswith("release/"):
            continue
        m = _NAMED.match(branch)
        if m:
            out.append(int(m.group(1)))
    return tuple(sorted(set(out)))


@dataclass(frozen=True)
class Finding:
    branch: str
    number: int | None
    says: str


def check(branches: Sequence[str],
          issues: Mapping[int, RawIssue],
          protected: Sequence[str] = ("main",)) -> tuple[Finding, ...]:
    """What is wrong with the branches, against the board.

    `issues` holds **both** states: a branch naming a closed project is the
    interesting case, and one naming an issue in neither state is a number that
    resolves to nothing at all.

    A branch that names no issue is not a finding. `release/*` and a throwaway
    probe are legitimate, and refusing to name them would make this a rule about
    naming rather than about the relationship #342 is concerned with.
    """
    out: list[Finding] = []
    for branch in branches:
        if branch in protected or branch.startswith("release/"):
            continue
        m = _NAMED.match(branch)
        if not m:
            continue
        number = int(m.group(1))
        raw = issues.get(number)
        if raw is None:
            out.append(Finding(branch, number,
                               "names #%d, which does not exist" % number))
            continue
        if raw.state == "CLOSED":
            # §2.12: deleted when the project is live and closed. Kept because
            # a release branch is rebuildable only from branches that still
            # exist -- so this is a finding, not a refusal.
            out.append(Finding(branch, number,
                               "names #%d, which is closed — delete it once the release "
                               "that carries it has shipped" % number))
            continue
        if raw.issue_type != "Project":
            out.append(Finding(branch, number,
                               "names #%d, a %s — a branch belongs to a project (docs/3.6 §2.12)"
                               % (number, raw.issue_type or "typeless issue")))
    return tuple(out)


def render(findings: Sequence[Finding], total: int, colour: bool = True) -> str:
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    red = (lambda s: f"\033[31m{s}\033[0m") if colour else (lambda s: s)
    green = (lambda s: f"\033[32m{s}\033[0m") if colour else (lambda s: s)

    out = [f"{bold('BRANCHES')}  {dim('R9 — against the project each names')}"]
    if not findings:
        out.append(f"  {green('ok')} {dim(f'{total} branch(es), each naming an open project')}")
        return "\n".join(out)
    for f in findings:
        out.append(f"  {red('!!')} {bold(f.branch)}  {f.says}")
    return "\n".join(out)
