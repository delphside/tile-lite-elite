"""D54's weekly digest: the brake's two measures, what landed, what was deleted.

#382, the job spec: *"a weekly digest, one issue comment — what landed, what
was deleted, the tooling share, and anything I decided that you might have
decided differently."*

**Derived, so it cannot flatter.** Three of the four parts come from git and
the board, not from memory of the week. A hand-written digest reports what its
author remembers, which is the work they are proud of; this one reports what
the repository actually shows, including a tooling share moving the wrong way.

**The fourth part cannot be derived and is not faked.** *Anything I decided
that you might have decided differently* is a judgement about someone else's
preferences. The tool leaves the section empty and says so, on the same rule as
`obligations.py` — something nothing can evidence must not read as *nothing to
report*, because an empty section and an unanswerable question look identical.

**The measure is docs/3.7's, not the one first proposed.** Owner, 2026-09-21:
*"The test is that we produce fewer issues and that they take less of my
time"*, narrowed the same day to non-functional issues. So the headline is the
count of `tooling` and `documentation` issues raised in the window, beside the
week before, and what the board reports as waiting on the owner. The tooling
share stays as an observation: its 45% figure is provisional and its horizon is
#383 finishing, not a date. Until 2026-09-27 this module still reported the
share against a 45% threshold and a 2026-10-17 date, and asked for a
confirmation the owner had already given, because the answer landed in docs/3.7
and not here.

**Deletions are counted first among equals**, because D54 says so: *"removing
tooling is as much in scope as adding it, and needs no more permission"*, and
the measure of success is the tooling share falling rather than the tooling
backlog being worked efficiently.
"""

from __future__ import annotations

import collections
import re
from dataclasses import dataclass, field
from datetime import date, timedelta

from . import repo
from .model import classify
from .sources import Snapshot
from .turn import waiting_on_owner

# docs/3.7's brake: non-functional means these two types of change.
NON_FUNCTIONAL = ("tooling", "documentation")
# The share when D54 was agreed, kept so the observation says where it moved
# from. Not a target.
MEASURED_AT = 55

SUBJECT = re.compile(r"^app [\d.]+ api [\d.]+: (.*)$")


@dataclass
class Digest:
    since: str
    until: str
    landed: list[tuple[str, str]] = field(default_factory=list)
    files_deleted: list[str] = field(default_factory=list)
    lines_added: int = 0
    lines_removed: int = 0
    tooling: int = 0
    total: int = 0
    by_type: collections.Counter = field(default_factory=collections.Counter)
    closed: list[tuple[int, str]] = field(default_factory=list)
    raised: list[tuple[int, str]] = field(default_factory=list)
    non_functional: list[tuple[int, str]] = field(default_factory=list)
    non_functional_before: int = 0
    waiting: list[tuple[int, str, str]] = field(default_factory=list)

    @property
    def share(self) -> int:
        return (self.tooling * 100 // self.total) if self.total else 0


def resolve(since: str, main: str = "origin/main") -> str:
    """A tag, a sha, or a date — a date becomes the last commit before it.

    Resolving to a commit rather than passing `--since` keeps every part of
    the digest on the same range: `git log --since` and `git diff A..B` do not
    agree about boundaries, and two counts of the same week a few lines apart
    is the defect this repository has already hit once, in the behind-main
    count.
    """
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
        sha = repo._git("rev-list", "-1", f"--before={since}", main).strip()
        return sha or since
    return since


def window_start(since: str) -> str:
    """The window's first day, as YYYY-MM-DD, whatever `since` was given as."""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
        return since
    return repo._git("log", "-1", "--format=%cs", since).strip() or since


def in_window(open_raw, closed_raw, start: str):
    """(raised, non-functional raised, non-functional raised the week before,
    closed), each within the window beginning `start`, a YYYY-MM-DD date.

    Raised whatever state it is in now: an issue raised and closed inside the
    week was still raised. Until 2026-09-27 only the open ones were counted,
    and closed was read from `updated_at`, so a comment on an old closed issue
    listed it as closed this week.
    """
    before = (date.fromisoformat(start) - timedelta(days=7)).isoformat()
    raised, non_functional, closed = [], [], []
    non_functional_before = 0
    for raw in list(open_raw) + list(closed_raw):
        created = (raw.created_at or "")[:10]
        is_nf = (raw.fields or {}).get("Type of change") in NON_FUNCTIONAL
        if created >= start:
            raised.append((raw.number, raw.title))
            if is_nf:
                non_functional.append((raw.number, raw.title))
        elif created >= before and is_nf:
            non_functional_before += 1
    for raw in closed_raw:
        if (raw.closed_at or "")[:10] >= start:
            closed.append((raw.number, raw.title))
    return sorted(raised), sorted(non_functional), non_functional_before, closed


def build(open_snapshot: Snapshot, closed_snapshot: Snapshot | None,
          since: str, until: str = "HEAD") -> Digest:
    d = Digest(since=since, until=until)
    start = window_start(since)

    rev = f"{resolve(since)}..{until}"
    log = repo._git("log", "--no-merges", "--format=%H%x1f%s", rev)
    for line in log.splitlines():
        if "\x1f" not in line:
            continue
        sha, subject = line.split("\x1f", 1)
        match = SUBJECT.match(subject)
        d.landed.append((sha[:7], match.group(1) if match else subject))

    d.files_deleted = [f for f in repo._git(
        "log", "--diff-filter=D", "--name-only", "--format=", rev).split() if f]

    stat = repo._git("diff", "--shortstat", rev)
    if add := re.search(r"(\d+) insertion", stat):
        d.lines_added = int(add.group(1))
    if rm := re.search(r"(\d+) deletion", stat):
        d.lines_removed = int(rm.group(1))

    everything = [classify(r) for r in open_snapshot.issues]
    issues = [i for i in everything if i.raw.issue_type != "PullRequest"]
    d.total = len(issues)
    d.by_type = collections.Counter(i.field("Type of change") or "unset"
                                    for i in issues)
    d.tooling = d.by_type.get("tooling", 0)

    # Pull requests are in the snapshot for this: a review waiting is his.
    for issue in everything:
        w = waiting_on_owner(issue)
        if w:
            d.waiting.append((issue.number, issue.title, w.asked))

    closed_raw = list(closed_snapshot.issues) if closed_snapshot else []
    (d.raised, d.non_functional, d.non_functional_before,
     d.closed) = in_window([i.raw for i in issues], closed_raw, start)
    return d


def render(d: Digest, judgements: list[str] | None = None) -> str:
    until = date.today().isoformat() if d.until == "HEAD" else d.until[:10]
    out = [f"# Weekly digest, {window_start(d.since)} to {until}", ""]

    # docs/3.7's brake, limit 1: fewer non-functional issues, and less of the
    # owner's time. Both counted, neither argued.
    out.append("## The brake: fewer non-functional issues, less of your time")
    out.append("")
    nf = len(d.non_functional)
    out.append(f"**{nf}** non-functional issues raised (`tooling` or `documentation`), "
               f"against **{d.non_functional_before}** in the seven days before.")
    if d.non_functional:
        out.append("")
    for number, title in d.non_functional:
        out.append(f"- #{number} {title}")
    out.append("")
    if d.waiting:
        things = "thing" if len(d.waiting) == 1 else "things"
        out.append(f"**{len(d.waiting)}** {things} the board reports as waiting on you:")
        out.append("")
        for number, title, action in d.waiting:
            out.append(f"- #{number} {title}: {action}")
    else:
        out.append("**Nothing** the board reports as waiting on you.")
    out.append("")
    # An observation, not the target (docs/3.7). Always name the starting
    # point, so a one-point move cannot read like a ten-point one.
    out.append(f"*The tooling share, as an observation:* {d.tooling} of {d.total} open "
               f"issues are `tooling`, **{d.share}%**, against {MEASURED_AT}% when D54 "
               "was agreed. Not the target: the 45% figure is provisional until "
               "#383's model has replaced the tooling it is replacing.")
    out.append("")
    out.append("| type | open | share |")
    out.append("| --- | --- | --- |")
    for kind, count in d.by_type.most_common():
        out.append(f"| `{kind}` | {count} | {count * 100 // max(1, d.total)}% |")

    out.append("")
    out.append(f"## What landed — {len(d.landed)} commits")
    out.append("")
    for sha, subject in d.landed[:40]:
        out.append(f"- `{sha}` {subject}")
    if len(d.landed) > 40:
        out.append(f"- …and {len(d.landed) - 40} more")

    out.append("")
    out.append("## What was deleted")
    out.append("")
    if d.files_deleted:
        for path in d.files_deleted:
            out.append(f"- `{path}`")
    else:
        out.append("Nothing was removed this week.")
    out.append("")
    out.append(f"{d.lines_added} lines added, {d.lines_removed} removed. "
               "D54: *removing tooling is as much in scope as adding it.*")

    if d.raised or d.closed:
        out.append("")
        out.append("## Issues")
        out.append("")
        if d.raised:
            out.append(f"### Raised ({len(d.raised)})")
            out.append("")
            for number, title in d.raised:
                out.append(f"- #{number} {title}")
        if d.closed:
            if d.raised:
                out.append("")
            out.append(f"### Closed ({len(d.closed)})")
            out.append("")
            for number, title in d.closed:
                out.append(f"- #{number} {title}")

    out.append("")
    out.append("## What I decided that you might have decided differently")
    out.append("")
    if judgements:
        out += [f"- {j}" for j in judgements]
    else:
        # Not derivable, and not to be reported as "nothing".
        out.append("*Not filled in. This section is a judgement about what you "
                   "would have wanted, which nothing in git or the board can "
                   "answer — an empty one here means it was not written, not "
                   "that there was nothing.*")
    return "\n".join(out)
