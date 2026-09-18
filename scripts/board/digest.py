"""D54's weekly digest: what landed, what was deleted, and the tooling share.

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

**Deletions are counted first among equals**, because D54 says so: *"removing
tooling is as much in scope as adding it, and needs no more permission"*, and
the measure of success is the tooling share falling rather than the tooling
backlog being worked efficiently.
"""

from __future__ import annotations

import collections
import re
from dataclasses import dataclass, field

from . import repo
from .model import classify
from .sources import Snapshot

# The threshold and horizon D54 proposes. The owner was asked to confirm or
# change them and has not, so they stand as proposed — which the digest says
# each time rather than letting an unconfirmed number harden into a fact.
THRESHOLD, MEASURED_AT, HORIZON = 45, 55, "2026-10-17"

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

    @property
    def share(self) -> int:
        return (self.tooling * 100 // self.total) if self.total else 0

    @property
    def direction(self) -> str:
        if self.share < THRESHOLD:
            return f"below the {THRESHOLD}% threshold"
        if self.share < MEASURED_AT:
            return f"falling, still above the {THRESHOLD}% threshold"
        return f"not falling — it was {MEASURED_AT}% when D54 was written"


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


def build(open_snapshot: Snapshot, closed_snapshot: Snapshot | None,
          since: str, until: str = "HEAD") -> Digest:
    d = Digest(since=since, until=until)

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

    issues = [classify(r) for r in open_snapshot.issues
              if r.issue_type != "PullRequest"]
    d.total = len(issues)
    d.by_type = collections.Counter(i.field("Type of change") or "unset"
                                    for i in issues)
    d.tooling = d.by_type.get("tooling", 0)

    # Anything raised inside the window, whatever state it is in now.
    for issue in issues:
        if issue.raw.created_at and issue.raw.created_at[:10] >= since[:10]:
            d.raised.append((issue.number, issue.title))
    if closed_snapshot:
        for raw in closed_snapshot.issues:
            if raw.updated_at and raw.updated_at[:10] >= since[:10]:
                d.closed.append((raw.number, raw.title))
    return d


def render(d: Digest, judgements: list[str] | None = None) -> str:
    out = [f"## Weekly digest — {d.since[:10]} to {d.until[:10]}", ""]

    out.append(f"### The tooling share: **{d.share}%**, {d.direction}")
    out.append("")
    # Always name the starting point, not only when the number is bad. Saying
    # "falling" without saying what from lets an improvement of one point read
    # like an improvement of ten.
    move = d.share - MEASURED_AT
    moved = ("unchanged from" if move == 0
             else f"{abs(move)} points {'below' if move < 0 else 'ABOVE'}")
    out.append(f"{d.tooling} of {d.total} open issues are type `tooling` — "
               f"{moved} the {MEASURED_AT}% measured when D54 was written. "
               f"Limit 1 is below {THRESHOLD}% by {HORIZON}.")
    out.append("")
    out.append("| type | open | share |")
    out.append("| --- | --- | --- |")
    for kind, count in d.by_type.most_common():
        out.append(f"| `{kind}` | {count} | {count * 100 // max(1, d.total)}% |")
    out.append("")
    out.append(f"*The {THRESHOLD}% threshold and the {HORIZON} horizon stand as "
               "proposed — D54 asked you to confirm or change them, and a "
               "sentence still does.*")

    out.append("")
    out.append(f"### What landed — {len(d.landed)} commits")
    out.append("")
    for sha, subject in d.landed[:40]:
        out.append(f"- `{sha}` {subject}")
    if len(d.landed) > 40:
        out.append(f"- …and {len(d.landed) - 40} more")

    out.append("")
    out.append("### What was deleted")
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
        out.append("### Issues")
        out.append("")
        if d.raised:
            out.append(f"**Raised ({len(d.raised)})**")
            for number, title in d.raised:
                out.append(f"- #{number} {title}")
        if d.closed:
            out.append(f"**Closed ({len(d.closed)})**")
            for number, title in d.closed:
                out.append(f"- #{number} {title}")

    out.append("")
    out.append("### What I decided that you might have decided differently")
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
