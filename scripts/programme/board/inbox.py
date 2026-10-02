"""R2 — what changed since I last looked.

Replaces `inbox.sh`, which built its own picture of the board to do it: it
fetched every issue a second time for titles and for open/closed dates, which
is the duplication #383 exists to remove. Here the snapshot is the model's, so
a thread arrives with what the model already knows about the issue — its kind
and the step it is at — rather than a bare number.

**Comments show what was said; the events section shows what was decided.** An
issue closed in silence produces no comment at all, so a comment listing never
reveals it. That distinction is `inbox.sh`'s and is kept.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from .model import Issue, RawIssue, classify
from .sources import Remark, Report


@dataclass(frozen=True)
class Thread:
    """One issue, and everything said on it inside the window."""

    number: int
    title: str
    kind: str | None
    step: str | None
    remarks: tuple[Remark, ...]

    @property
    def from_owner(self) -> int:
        return sum(1 for r in self.remarks if r.who == "owner")


@dataclass(frozen=True)
class Event:
    number: int
    title: str
    what: str          # "opened" | "closed" | "opened+closed"


@dataclass(frozen=True)
class Inbox:
    since: str
    threads: tuple[Thread, ...]
    events: tuple[Event, ...]
    # What the scheduled workflows wrote: owner, 2026-09-27, "can you add a
    # hook so you notice a new report?" Its own section, because a report is
    # neither something somebody said nor a decision somebody made.
    reports: tuple[Report, ...] = ()

    @property
    def from_owner(self) -> int:
        return sum(t.from_owner for t in self.threads)


def build(issues: Sequence[RawIssue], remarks: Sequence[Remark],
          since_iso: str, reports: Sequence[Report] = ()) -> Inbox:
    """Group remarks under the issues they were made on, and list what opened
    or closed in the window.

    `issues` is every issue in both states — the same snapshot every other
    consumer uses. An issue a remark names but the snapshot does not hold still
    gets a thread: a comment on something outside the window's board is still
    something that was said.
    """
    by_number: dict[int, RawIssue] = {i.number: i for i in issues}

    grouped: dict[int, list[Remark]] = {}
    for r in remarks:
        grouped.setdefault(r.number, []).append(r)

    threads = []
    for number in sorted(grouped):
        raw = by_number.get(number)
        typed: Issue | None = classify(raw) if raw else None
        threads.append(Thread(
            number=number,
            title=raw.title if raw else "",
            kind=type(typed).__name__ if typed else None,
            step=typed.step if typed else None,
            remarks=tuple(grouped[number]),
        ))

    events = []
    for raw in issues:
        opened = bool(raw.created_at and raw.created_at >= since_iso)
        closed = bool(raw.closed_at and raw.closed_at >= since_iso)
        if not (opened or closed):
            continue
        # **Opened *and* closed inside the window needs saying.** Reporting only
        # "opened" reads as still-open, which after a week away is the one thing
        # somebody would act on wrongly. `inbox.sh` learned this.
        what = "opened+closed" if (opened and closed) else ("opened" if opened else "closed")
        events.append(Event(raw.number, raw.title, what))
    events.sort(key=lambda e: e.number)

    return Inbox(since=since_iso, threads=tuple(threads), events=tuple(events),
                 reports=tuple(reports))


def _at(r: Remark) -> str:
    return r.when or r.created


def unanswered(remarks: Sequence[Remark]) -> tuple[Remark, ...]:
    """The owner's comments that Claude has not answered, however old.

    **Answered means a later comment from Claude on the same issue.** An
    automatic comment is not an answer -- `deploy.sh`'s announcement is read as
    `deploy` and a workflow's as `bot`, neither as `claude`, so a deploy note
    cannot hide a question. Owner, 2026-10-01 (#454). Ordered by when it was
    first written, not edited, so correcting a comment does not reopen it. A
    reply at the same second counts as an answer: nothing can order them.
    """
    last_answer: dict[int, str] = {}
    for r in remarks:
        if r.who == "claude":
            last_answer[r.number] = max(last_answer.get(r.number, ""), _at(r))
    return tuple(r for r in remarks
                 if r.who == "owner" and _at(r) > last_answer.get(r.number, ""))


def waiting_for_claude(issues: Sequence[RawIssue], remarks: Sequence[Remark]) -> tuple[Thread, ...]:
    """One thread per open issue holding unanswered comments, the one most
    recently asked on last, so a cap that drops the front drops the oldest."""
    by_number: dict[int, RawIssue] = {i.number: i for i in issues}
    grouped: dict[int, list[Remark]] = {}
    for r in unanswered(remarks):
        grouped.setdefault(r.number, []).append(r)
    threads = []
    for number, rs in grouped.items():
        raw = by_number.get(number)
        # A closed issue or a merged pull request has nothing left to do: what was said last
        # was settled by closing it. Found on the first run, 2026-10-01, when
        # the unlimited list held 137 issues, most of them closed.
        if raw is not None and raw.state != "OPEN":
            continue
        typed: Issue | None = classify(raw) if raw else None
        threads.append(Thread(number, raw.title if raw else "",
                              type(typed).__name__ if typed else None,
                              typed.step if typed else None, tuple(rs)))
    return tuple(sorted(threads, key=lambda t: _at(t.remarks[-1])))


FIRST_LINE = 120


def render_waiting(threads: Sequence[Thread], colour: bool = True, limit: int = 12) -> str:
    """Each issue with the first words of what the owner asked, newest last.

    Capped, because a to-do list that grows without a time limit must not make
    the session-start summary the wall of text it replaced. Says how many it
    left out and where the rest are."""
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    if not threads:
        return dim("nothing from the owner is waiting for an answer")
    out: list[str] = []
    shown = threads[-limit:] if len(threads) > limit + 1 else threads
    if len(threads) > len(shown):
        out.append(dim(f"...{len(threads) - len(shown)} earlier (board-inbox.py --open --uncapped)"))
    for t in shown:
        context = " · ".join(x for x in (t.kind, t.step) if x)
        head = f"{bold(f'#{t.number}')}  {t.title[:60]}"
        if context:
            head += f"  [{context}]"
        out.append(head)
        for r in t.remarks:
            out.append(f"  > {r.when}  {r.text[:FIRST_LINE]}")
    return "\n".join(out)


def render(inbox: Inbox, colour: bool = True) -> str:
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    out: list[str] = []
    out.append(f"{bold('INBOX')}  {dim(f'since {inbox.since}')}")

    if not inbox.threads:
        out.append(f"\n  {dim('no comments in this window')}")
    for t in inbox.threads:
        context = " · ".join(x for x in (t.kind, t.step) if x)
        head = f"{bold(f'#{t.number}')}  {dim(t.title[:66])}"
        if context:
            head += f"  {dim(f'[{context}]')}"
        out.append("")
        out.append(head)
        for r in t.remarks:
            prefix = "(review) " if r.on_diff else ""
            if r.who == "owner":
                out.append(f"  {bold('>')} {dim(r.when)}  {prefix}{r.text}")
            elif r.who == "bot":
                out.append(f"    {dim(r.when)}  {dim('[bot] ' + prefix + r.text)}")
            elif r.who == "deploy":
                out.append(f"    {dim(r.when)}  {dim('[deploy.sh] ' + prefix + r.text)}")
            else:
                out.append(f"    {dim(r.when)}  {dim(prefix + r.text)}")

    out.append("")
    out.append(bold("REPORTS FROM THE SCHEDULED WORKFLOWS"))
    if not inbox.reports:
        out.append(f"  {dim('no report opened, updated or closed')}")
    for r in inbox.reports:
        # Closed is the workflow clearing its own report, which is news too.
        out.append(f"  #{r.number:<5} {r.state.lower():<7} {r.when}  {r.title[:52]}")

    out.append("")
    out.append(bold("OPENED OR CLOSED"))
    if not inbox.events:
        out.append(f"  {dim('nothing opened or closed')}")
    for e in inbox.events:
        out.append(f"  #{e.number:<5} {e.what:<13} {e.title[:56]}")

    out.append("")
    out.append(dim("Read-only, derived at run time. '>' is what the owner typed."))
    return "\n".join(out)
