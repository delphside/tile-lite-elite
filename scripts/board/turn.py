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
| an unanswered question in a body | an unticked `- [ ]` labelled **owner** |

**The fourth source was underivable until 2026-09-18.** Bodies used `- [ ]` for
work of every kind and nothing distinguished a box the owner must tick from one
Claude must, so R1 printed the gap under every run rather than pretending the
absence of a signal was the absence of work. Owner: *"Label Checkboxes
consistently as Claude or owner so the tools can differentiate."* Now they do,
and what remains reportable is a box with **no** label — which this still
refuses to guess at, on the same rule as `obligations.py`: something nothing can
evidence must not read as *nothing to do*.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

from .model import (
    OWNER,
    Decision,
    Issue,
    PullRequest,
    StandaloneProject,
    WorkPackage,
    classify,
)
from .sources import Snapshot, step_ages, token_days_left

DELIVERING = (WorkPackage, StandaloneProject)

# **A box is not waiting until it is due.** Labelling every checkbox made 126
# of them visible, and listing all the owner's at once turned R1 into a list of
# everything that will ever need him -- which is the report that gets skimmed,
# and then the one line that mattered is missed.
#
# So a box counts when its issue has reached a step where the owner acts. A
# Requirement never qualifies: its `What would show it works` boxes describe
# evidence a future delivery will produce, not work waiting on anybody today.
DUE_AT: dict[str, tuple[str, ...]] = {
    "ParentProject": ("User testing", "Deployment", "Post-deployment",
                      "Project Closedown"),
    "WorkPackage": ("User testing", "Deployment", "Post-deployment",
                    "Project Closedown"),
    "StandaloneProject": ("User testing", "Deployment", "Post-deployment",
                          "Project Closedown"),
    "Decision": ("Asked",),
    "PullRequest": ("Awaiting review", "Changes requested"),
    "Requirement": (),
}


def boxes_are_due(issue: Issue) -> bool:
    return issue.step in DUE_AT.get(issue.kind, ())

UNLABELLED = (
    "a checkbox with no owner",
    "An unticked box labelled neither **owner** nor **Claude** is waiting on "
    "nobody. It is counted, never assigned: guessing from the heading is the "
    "inference the label exists to replace.",
)


@dataclass(frozen=True)
class Waiting:
    """One thing the owner has to do, and how long it has sat."""

    issue: Issue
    asked: str
    source: str
    days: float | None = None
    dated: bool = False

    @property
    def age(self) -> float:
        return self.days if self.days is not None else (self.issue.quiet_days or 0.0)

    @property
    def line(self) -> str:
        days = self.age
        if days < 1:
            age = "today"
        else:
            # `waiting` is the real thing: the timeline says when the field
            # reached this value. `quiet` is the fallback and a weaker claim --
            # last activity of any kind, which a comment resets. Naming them
            # differently is what stops the weaker one being read as the
            # stronger.
            age = f"{int(days)}d {'waiting' if self.dated else 'quiet'}"
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

    # The fourth source. Anywhere in the body, on any type: a box he has to
    # tick is his move whatever section it sits in -- once it is due.
    his = issue.unticked_for(OWNER) if boxes_are_due(issue) else []
    if his:
        first = his[0].text
        more = f" (+{len(his) - 1} more)" if len(his) > 1 else ""
        return Waiting(issue, f"{first[:60]}{more}", "checkbox")
    return None


def whats_waiting(snapshot: Snapshot, dated: bool = True) -> list[Waiting]:
    """Longest-waiting first, because that is the only signal the board gives
    that something is stuck.

    The age comes from the timeline -- when the step field reached the value it
    holds now -- and is asked only for the handful actually waiting, not for
    the whole board. Without it the ordering falls back to last activity, which
    is a floor rather than a measure and says so in the output.
    """
    found = [w for w in (waiting_on_owner(classify(raw)) for raw in snapshot.issues)
             if w is not None]
    if dated and found:
        # Pull requests are not issues: `issue(number:)` on a pull request
        # number fails, and its step lives on the board rather than in the
        # issue timeline, so there is nothing to read even if it did not.
        ages = step_ages([(w.issue.number, w.issue.step_field, w.issue.step or "")
                          for w in found
                          if not isinstance(w.issue, PullRequest)])
        found = [replace(w, days=ages.get(w.issue.number), dated=w.issue.number in ages)
                 for w in found]
    return sorted(found, key=lambda w: (-w.age, w.issue.number))


BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"


def render(snapshot: Snapshot, colour: bool = True,
           dated: bool = True) -> tuple[str, int]:
    """The report, and how many things are waiting."""
    def paint(code: str, text: str) -> str:
        return f"{code}{text}{RESET}" if colour else text

    waiting = whats_waiting(snapshot, dated=dated)
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

    issues = [classify(raw) for raw in snapshot.issues]
    later = sum(len(i.unticked_for(OWNER)) for i in issues if not boxes_are_due(i))
    if later:
        out.append("")
        out.append(paint(DIM, f"  {later} box(es) are yours but not yet due — "
                              "they belong to work that has not reached a step "
                              "where you act."))

    # The token is the owner's to renew and nothing else warns: GitHub emails
    # about 2FA and says nothing about this, so the first symptom would be a
    # command failing in the middle of something else. #309.
    if dated:
        left = token_days_left()
        if left is not None:
            out.append("")
            line = f"  the token gh runs on expires in {left} days"
            out.append(line if left > 30 else paint(BOLD, line + " — #309"))

    orphans = sum(len(i.unlabelled_boxes) for i in issues)
    if orphans:
        out.append("")
        out.append(paint(DIM, f"  not checked: {orphans} × {UNLABELLED[0]}."))
        out.append(paint(DIM, f"  {UNLABELLED[1]}"))
    return "\n".join(out), len(waiting)
