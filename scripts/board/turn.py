"""R1: what needs the owner.

Owner's purpose, from `reports.md`: *"The owner never has to scan the board to
find what is waiting on him. Everything else is Claude's to find and move."*

So this answers one question per issue — **is the next move the owner's?** — and
says nothing about anything else. A report that also lists what is going well
is a report that gets skimmed, and then the one line that mattered is missed.

**Whose turn is a derived fact with four sources.** Three can be derived today.
The fourth cannot, and that is reported rather than passed over:

| source | how it is read |
| --- | --- |
| a decision waiting to be answered | `Decision State` is `Asked` |
| a pull request waiting to be reviewed | `PR State` is `Awaiting review` |
| a phase only the owner can advance | `User testing`, with Preview boxes unticked |
| **an unanswered question in a body** | **no convention exists — see `UNDERIVABLE`** |

The same discipline as `obligations.py`: something nothing can evidence must
not read as *nothing to do*. An empty report and an unenforceable rule look
identical from the outside, and only one of them is good news.
"""

from __future__ import annotations

from dataclasses import dataclass

from .model import Decision, Issue, PullRequest, StandaloneProject, WorkPackage, classify
from .sources import Snapshot

DELIVERING = (WorkPackage, StandaloneProject)

UNDERIVABLE = (
    "an unanswered question in an issue body",
    "No convention marks one. Bodies use `- [ ]` for work of every kind, and "
    "nothing distinguishes a box the owner must tick from one Claude must. A "
    "heading the owner answers under — or a label — would make this derivable; "
    "until then R1 cannot see this source and does not pretend to.",
)


@dataclass(frozen=True)
class Waiting:
    """One thing the owner has to do, and how long it has sat."""

    issue: Issue
    asked: str
    source: str

    @property
    def quiet_days(self) -> float:
        return self.issue.quiet_days or 0.0

    @property
    def line(self) -> str:
        days = self.quiet_days
        age = "today" if days < 1 else f"{int(days)}d quiet"
        return f"#{self.issue.number} {self.issue.title}  —  {self.asked}  ({age})"


def waiting_on_owner(issue: Issue) -> Waiting | None:
    """The three derivable sources, in the order they cost the owner time."""
    if isinstance(issue, Decision) and issue.step == "Asked":
        return Waiting(issue, "answer the question", "decision")

    if isinstance(issue, PullRequest) and issue.step == "Awaiting review":
        return Waiting(issue, "review: approve or request changes", "pull request")

    # The one phase whose exit only the owner can evidence: somebody has to
    # have used it in a browser, and only he can say so.
    if isinstance(issue, DELIVERING) and issue.step == "User testing":
        unticked = issue.unticked_in("Functional user tests — Preview")
        if unticked:
            plural = "" if unticked == 1 else "s"
            return Waiting(issue, f"run {unticked} browser test{plural}",
                           "user testing")
    return None


def whats_waiting(snapshot: Snapshot) -> list[Waiting]:
    """Longest-quiet first: the only signal the board gives that something is
    stuck is that nothing has happened to it."""
    found = [w for w in (waiting_on_owner(classify(raw)) for raw in snapshot.issues)
             if w is not None]
    return sorted(found, key=lambda w: (-w.quiet_days, w.issue.number))


BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"


def render(snapshot: Snapshot, colour: bool = True) -> tuple[str, int]:
    """The report, and how many things are waiting."""
    def paint(code: str, text: str) -> str:
        return f"{code}{text}{RESET}" if colour else text

    waiting = whats_waiting(snapshot)
    out = []

    if waiting:
        out.append(paint(BOLD, f"{len(waiting)} waiting on you"))
        out.append("")
        for w in waiting:
            out.append("  " + w.line)
    else:
        # Said plainly. Blank space is indistinguishable from a broken report.
        out.append(paint(BOLD, "Nothing is waiting on you."))
        out.append(paint(DIM, "  No decision is unanswered, no pull request is "
                              "awaiting review, and no delivery is in user testing."))

    out.append("")
    out.append(paint(DIM, f"  not checked: {UNDERIVABLE[0]}."))
    out.append(paint(DIM, f"  {UNDERIVABLE[1]}"))
    return "\n".join(out), len(waiting)
