"""Whether the milestone being built carries only work that exists.

Moved from `verify.sh`'s `check_milestone`, the last of that script's direct
GitHub calls. It asked GitHub for the milestone's open issues, then per issue
for its sub-issues to tell a parent from a package, then again for its parent
-- three questions for one row, all of them in the snapshot already.

**It joins the board to git, which is what makes it different from the other
two moved on 2026-09-21.** The board says what is meant to ship; `Refs #N` in
the history says what was written. Neither half is evidence on its own, and the
finding is the disagreement between them.

**The parent's commits are reported as a fact, never as credit.** A package
split out after its commits landed carries the parent's number and cannot be
made to carry its own -- #373 was split from #297 the day after `1036e1c` said
`Refs #297`, and no rewrite can fix that, because the commit is the one being
deployed. Crediting the parent was tried on 2026-09-10 and was wrong: #363 is
delivery 2 of #301 and unstarted, and #301's delivery-1 commits made it read as
merged. A parent with two packages cannot say which of them a commit belongs
to, so claiming is a guess, and the guess exonerates the very case the check
exists for. So the package stays unbuilt and the reader is given the one fact
that settles it in a second. #375.

**Gate-adjacent, so it matches the gate deliberately.** `deploy.sh` refuses;
this is the pre-flight that says so first, and `repo.mentions_on` is written to
count exactly what `issue-mentions.sh` counts for it. A pre-flight that passes
where the gate refuses is worse than no pre-flight: the release stops anyway,
at the point where stopping costs most.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence

from .model import Issue, ParentProject, PullRequest


@dataclass(frozen=True)
class Carried:
    """One issue in the milestone, and what the history says about it."""

    number: int
    title: str
    kind: str
    mentions: int
    a_parent: bool
    parent: int | None = None
    parent_mentions: int = 0

    @property
    def unbuilt(self) -> bool:
        """Nothing in the history names it, and it is not a parent.

        A parent is never unbuilt here because it is never built here: it owns
        the requirements and the design while its packages carry the commits
        (D51), so a rule that asked it for its own would be a finding nobody
        can clear. The owner, 2026-09-08: *"as with Route a parent does not
        need a milestone, but one can be set. It should be ignored."*
        """
        return not self.a_parent and self.mentions == 0


def carried(issues: Sequence[Issue], milestone: str,
            mentions: Callable[[int], int]) -> tuple[Carried, ...]:
    """Every open issue in `milestone`, with its commit count and its parent's.

    `mentions` is passed in rather than read here: this module decides what the
    counts *mean*, `repo.mentions_on` decides what counts. Keeping the two
    apart is what lets the meaning be tested without a git history to build.

    Every type is included, not only deliveries. A Requirement or a Decision
    sitting in a release milestone with no commit behind it is precisely the
    thing this catches -- #380 and #379 shipped in 0.8.1 through a warning --
    and filtering to Projects would make the check blind to it.

    **Pull requests are not issues**, though the snapshot holds them and they
    can carry a milestone. `gh issue list --milestone` never returned one, so
    including them now would invent findings for a review surface that ships
    nothing of its own.
    """
    out = []
    for issue in issues:
        if isinstance(issue, PullRequest):
            continue
        if issue.raw.milestone != milestone:
            continue
        # An untyped issue is classified as a Requirement so that some rule
        # owns it (#361), but the report says `untyped`: the type is the thing
        # to fix, and printing the default would hide it.
        kind = "untyped" if issue.type_was_defaulted else issue.kind
        if isinstance(issue, ParentProject):
            out.append(Carried(issue.number, issue.title, kind,
                               mentions(issue.number), a_parent=True))
            continue
        count = mentions(issue.number)
        parent = issue.parent if count == 0 else None
        out.append(Carried(issue.number, issue.title, kind, count,
                           a_parent=False, parent=parent,
                           parent_mentions=mentions(parent) if parent else 0))
    return tuple(sorted(out, key=lambda c: c.number))


def unbuilt(rows: Sequence[Carried]) -> tuple[Carried, ...]:
    return tuple(r for r in rows if r.unbuilt)


def render(rows: Sequence[Carried], milestone: str, colour: bool = True) -> str:
    bold = (lambda s: f"\033[1m{s}\033[0m") if colour else (lambda s: s)
    dim = (lambda s: f"\033[2m{s}\033[0m") if colour else (lambda s: s)
    red = (lambda s: f"\033[31m{s}\033[0m") if colour else (lambda s: s)
    green = (lambda s: f"\033[32m{s}\033[0m") if colour else (lambda s: s)

    out = [f"{bold('MILESTONE')}  {dim(f'{milestone} carries only built work')}"]
    if not rows:
        out.append(f"  {green('ok')} {dim(f'milestone {milestone} has no open issues')}")
        return "\n".join(out)
    for row in rows:
        head = f"{bold(f'#{row.number}')} {dim(row.kind[:11])} {row.title[:46]}"
        if row.a_parent:
            out.append(f"  {green('ok')} {head}  "
                       f"{dim('a parent — its packages carry the commits')}")
        elif row.mentions:
            out.append(f"  {green('ok')} {head}  "
                       f"{dim(f'{row.mentions} commits')}")
        elif row.parent and row.parent_mentions:
            # The fact, not the credit. It still reads as unbuilt.
            where = (f"no commit mentions this "
                     f"(parent #{row.parent} has {row.parent_mentions})")
            out.append(f"  {red('!!')} {head}  {dim(where)}")
        else:
            out.append(f"  {red('!!')} {head}  {dim('no commit mentions this')}")
    missing = unbuilt(rows)
    if missing:
        out.append(f"  {red('!!')} {dim('unbuilt:')} "
                   + " ".join(f"#{r.number}" for r in missing))
    return "\n".join(out)
