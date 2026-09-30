"""Which pull requests the board is missing, and whose `PR State` is wrong.

**The field is derived, never typed.** `sources.pr_state` reads it from
`isDraft`, `reviewDecision` and whether a review is requested; the `approved`
and `awaiting-review` labels were deleted in #219 for being a second store of
what GitHub already knew, and a column set by hand went wrong within a day
(#338 and #341 sat in Approved after merging). So the board is generated from
the source, like `docs/1.5`: where the field disagrees, the field is wrong.

**It also adds what is missing.** The project's auto-add workflow has no API,
so nothing can widen it to pull requests; adding them here is idempotent.

**A pull request that requests nobody is waiting on nobody.** `gh pr create
--reviewer` accepts a login it cannot use and requests no one, and the ladder
then says Drafting, so nothing tells the owner a review is waiting. It is
reported, never fixed: requesting a review notifies somebody.

Run by `scripts/programme/board/board-pr-state.py`. The decision is here, apart from GitHub,
so it can be tested on its own.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Iterable

from .model import RawBoardItem, RawPullRequest
from .sources import Unavailable, pr_state


@dataclass(frozen=True)
class Drift:
    """One pull request the board does not agree with, and what it needs."""

    number: int
    node_id: str
    want: str               # what GitHub says, by the ladder
    have: str | None        # what the board says; None when unset or absent
    item_id: str | None     # its board item; None when it is not on the board
    unrequested: bool       # open and ready, but nobody's review is requested

    @property
    def missing(self) -> bool:
        return self.item_id is None

    @property
    def wrong(self) -> bool:
        return self.have != self.want

    @property
    def drifted(self) -> bool:
        return self.missing or self.wrong


def want(pr: RawPullRequest) -> str:
    """The `PR State` GitHub's own state gives this pull request."""
    return pr_state(pr.draft, pr.review, pr.reviewers, pr.state)


def requests_nobody(pr: RawPullRequest) -> bool:
    """Open, not a draft, and no review requested, given or decided."""
    return (pr.state == "OPEN" and not pr.draft and not pr.reviewers
            and not pr.review and not pr.reviews)


def plan(prs: Iterable[RawPullRequest],
         board: Iterable[RawBoardItem]) -> list[Drift]:
    """Every pull request needing an add, a correction or a reviewer."""
    items: dict[int, RawBoardItem] = {}
    for item in board:
        items.setdefault(item.number, item)
    out = []
    for pr in prs:
        item = items.get(pr.number)
        d = Drift(pr.number, pr.node_id, want(pr),
                  item.pr_state if item else None,
                  item.item_id if item else None,
                  requests_nobody(pr))
        if d.drifted or d.unrequested:
            out.append(d)
    return out


@dataclass
class Tally:
    """What a run did or found, and the lines it says."""

    added: int = 0
    corrected: int = 0
    drifted: int = 0
    unrequested: int = 0
    # (to stderr, text), in the order they were said
    lines: list[tuple[bool, str]] = field(default_factory=list)

    def say(self, text: str, err: bool = False) -> None:
        self.lines.append((err, text))


def _unrequested(tally: Tally, d: Drift, reviewer: str) -> None:
    tally.unrequested += 1
    tally.say(f"  #{d.number} is open and requests nobody's review — "
              "it is waiting on nobody", err=True)
    tally.say(f"        gh api -X POST repos/{{owner}}/{{repo}}/pulls/{d.number}"
              "/requested_reviewers \\", err=True)
    tally.say(f"          -f 'reviewers[]={reviewer}'", err=True)


def check(drifts: Iterable[Drift], reviewer: str) -> Tally:
    """Report the drift and change nothing."""
    tally = Tally()
    for d in drifts:
        if d.missing:
            tally.say(f"  #{d.number} is not on the board — should be '{d.want}'")
        elif d.wrong:
            tally.say(f"  #{d.number} says '{d.have or 'unset'}', GitHub says '{d.want}'")
        if d.drifted:
            tally.drifted += 1
        if d.unrequested:
            _unrequested(tally, d, reviewer)
    return tally


def apply(drifts: Iterable[Drift], add: Callable[[str], str],
          set_value: Callable[[str, str], None], reviewer: str) -> Tally:
    """Add what is missing and set what is wrong.

    `add(node_id)` returns the new item's id and `set_value(item_id, value)`
    writes the field; either raises `Unavailable` when GitHub refuses. A
    failed add is reported and not counted, and nothing is set on an item that
    does not exist.
    """
    tally = Tally()
    for d in drifts:
        item, have = d.item_id, d.have
        if d.drifted:
            tally.drifted += 1
        if d.missing:
            try:
                item = add(d.node_id)
            except Unavailable:
                item = None
            if item:
                tally.added += 1
                have = None
            else:
                tally.say(f"  #{d.number} could not be added", err=True)
        if d.unrequested:
            _unrequested(tally, d, reviewer)
        if item is None or have == d.want:
            continue
        try:
            set_value(item, d.want)
        except Unavailable as exc:
            tally.say(f"  #{d.number} could not be set to '{d.want}' ({exc})", err=True)
            continue
        tally.corrected += 1
        tally.say(f"  #{d.number} {have or 'unset'} -> {d.want}")
    return tally
