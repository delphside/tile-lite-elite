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
from datetime import date

from .model import (
    CLAUDE,
    OWNER,
    Box,
    Decision,
    Issue,
    Recurring,
    PullRequest,
    StandaloneProject,
    WorkPackage,
    classify,
)
from . import repo
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


# **One step is due in part, not in whole.** At `Design and Test Approach` most
# of a project's boxes are future evidence -- the test approach describes what a
# delivery will produce, and listing it now is the flood `DUE_AT` exists to
# stop. A box under `Design` is the opposite: a question asked today, of
# somebody who is here today. #291's two design questions were written on
# 2026-09-21 and sat in *not yet due* the moment they were written, which is the
# one place this report must not put a question.
DUE_SECTIONS: dict[str, tuple[str, ...]] = {
    "Design and Test Approach": ("Design",),
}

PROJECTS = ("ParentProject", "WorkPackage", "StandaloneProject")


# **A recurrence is due on its date, whatever phase its issue is in.** #291 R2.
# `DUE_AT` gates *checkboxes*, because a box written at design describes work a
# later step will do. A date does not describe anything -- it is the statement
# that this comes round again, and a review that falls due while its project
# sits at `Design and Test Approach` is due then, not when the project moves.
def due_recurrences(issue: Issue, who: str, today: date) -> list[Recurring]:
    return [r for r in issue.recurrences
            if r.who == who and r.overdue_by(today) >= 0]


def boxes_are_due(issue: Issue) -> bool:
    return issue.step in DUE_AT.get(issue.kind, ())


def due_boxes(issue: Issue, who: str) -> list[Box]:
    """The boxes of `who`'s that are waiting now rather than eventually.

    Whole-step first, then the part-step above. A step in neither owes
    nothing: that is `DUE_AT`'s judgement and this does not soften it.
    """
    if boxes_are_due(issue):
        return issue.unticked_for(who)
    if issue.kind in PROJECTS and issue.step in DUE_SECTIONS:
        out = []
        for heading in DUE_SECTIONS[issue.step]:
            out += [b for b in issue.boxes_in(heading)
                    if not b.ticked and b.who == who]
        return out
    return []

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
    # Some work is not owed until it has sat a while. A post-deployment review
    # is due after seven days, not the moment the deploy lands.
    due_after: float = 0.0

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

    # The fifth source, #291 R2: something that comes round again. Ahead of
    # the boxes because a date that has passed is a stronger claim on
    # somebody's attention than a box with no clock on it at all.
    recurring = due_recurrences(issue, OWNER, date.today())
    if recurring:
        first = min(recurring, key=lambda r: r.due)
        return Waiting(issue, first.text, "recurrence",
                       days=float(first.overdue_by(date.today())), dated=True)

    # The fourth source. Anywhere in the body, on any type: a box he has to
    # tick is his move whatever section it sits in -- once it is due.
    his = due_boxes(issue, OWNER)
    if his:
        first = his[0].text
        more = f" (+{len(his) - 1} more)" if len(his) > 1 else ""
        return Waiting(issue, f"{first[:60]}{more}", "checkbox")
    return None


# A delivery at Post-deployment owes a review after this long. `actions.py`'s
# REVIEW_DUE_DAYS, kept at its value so the move changes nothing.
REVIEW_DUE_DAYS = 7

# A delivery carrying this waits for the next release and owes nobody an
# action: the difference between "you have not done this" and "this cannot be
# done yet". Without it a Release Check project nags for a review for ever,
# which is #310.
RELEASE_CHECK = "Release Check"


def waiting_on_claude(issue: Issue) -> Waiting | None:
    """The mirror of `waiting_on_owner`. Same question, other side.

    Whose turn it is has exactly two answers, and a model that can only name
    one of them leaves the other implicit -- which is how `actions.py --claude`
    came to be the only thing that could say what Claude owed, wired into a
    single hook.
    """
    if isinstance(issue, PullRequest):
        if issue.step == "Approved":
            return Waiting(issue, "approved — mine to merge", "pull request")
        if issue.step == "Changes requested":
            return Waiting(issue, "make the changes, then re-request the review",
                           "pull request")
        return None

    if (isinstance(issue, DELIVERING) and issue.step == "Post-deployment"
            and RELEASE_CHECK not in issue.labels):
        return Waiting(issue, "post-deployment review is due — "
                              "docs/templates/post-deployment-review.md",
                       "post-deployment", due_after=REVIEW_DUE_DAYS)

    recurring = due_recurrences(issue, CLAUDE, date.today())
    if recurring:
        first = min(recurring, key=lambda r: r.due)
        return Waiting(issue, first.text, "recurrence",
                       days=float(first.overdue_by(date.today())), dated=True)

    mine = due_boxes(issue, CLAUDE)
    if mine:
        first = mine[0].text
        more = f" (+{len(mine) - 1} more)" if len(mine) > 1 else ""
        return Waiting(issue, f"{first[:60]}{more}", "checkbox")
    return None


def whats_waiting(snapshot: Snapshot, dated: bool = True,
                  who: str = OWNER) -> list[Waiting]:
    """Longest-waiting first, because that is the only signal the board gives
    that something is stuck.

    The age comes from the timeline -- when the step field reached the value it
    holds now -- and is asked only for the handful actually waiting, not for
    the whole board. Without it the ordering falls back to last activity, which
    is a floor rather than a measure and says so in the output.
    """
    rule = waiting_on_owner if who == OWNER else waiting_on_claude
    found = [w for w in (rule(classify(raw)) for raw in snapshot.issues)
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
    # Dropped only once the age is known: without a date there is nothing to
    # compare, and guessing "probably old enough" would make the report claim
    # work is owed when nothing says so.
    found = [w for w in found if not (w.due_after and w.dated and w.age < w.due_after)]
    return sorted(found, key=lambda w: (-w.age, w.issue.number))


BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"


def render(snapshot: Snapshot, colour: bool = True, dated: bool = True,
           who: str = OWNER) -> tuple[str, int]:
    """The report, and how many things are waiting."""
    def paint(code: str, text: str) -> str:
        return f"{code}{text}{RESET}" if colour else text

    waiting = whats_waiting(snapshot, dated=dated, who=who)
    subject = "you" if who == OWNER else "Claude"
    out = []

    if waiting:
        out.append(paint(BOLD, f"{len(waiting)} waiting on {subject}"))
        out.append("")
        for w in waiting:
            out.append("  " + w.line)
    else:
        # Said plainly. Blank space is indistinguishable from a broken report.
        out.append(paint(BOLD, f"Nothing is waiting on {subject}."))
        if who == OWNER:
            out.append(paint(DIM, "  No decision is unanswered, no pull request is "
                                  "awaiting review, and no delivery is in user testing."))
        else:
            out.append(paint(DIM, "  No pull request is mine to move, no "
                                  "post-deployment review is due, and no checkbox "
                                  "labelled Claude is outstanding."))

    issues = [classify(raw) for raw in snapshot.issues]
    later = sum(len(i.unticked_for(who)) - len(due_boxes(i, who))
                for i in issues if not boxes_are_due(i))
    if later:
        out.append("")
        whose = "yours" if who == OWNER else "Claude's"
        out.append(paint(DIM, f"  {later} box(es) are {whose} but not yet due — "
                              "they belong to work that has not reached a step "
                              "where you act."))

    # The token is the owner's to renew and nothing else warns: GitHub emails
    # about 2FA and says nothing about this, so the first symptom would be a
    # command failing in the middle of something else. #309.
    if dated and who == OWNER:
        left = token_days_left()
        if left is not None:
            out.append("")
            line = f"  the token gh runs on expires in {left} days"
            out.append(line if left > 30 else paint(BOLD, line + " — #309"))

    # **A red main is Claude's, and this is the report that says what is his.**
    # `programme.py` already says so -- "nothing releases from a red main, and
    # it is Claude's to fix rather than the owner's" -- but it says it in the
    # status report. Somebody asking what is waiting on Claude was told nothing
    # was, which was the last of `actions.py`'s extras still outside R1.
    #
    # Still pending is not red: an absent answer must not read as a failure any
    # more than as a pass, which is `ci_red_on_main`'s own rule.
    if dated and who != OWNER:
        red = repo.ci_red_on_main()
        if red:
            out.append("")
            out.append(paint(BOLD, f"  CI is red on main: {red}"))
            out.append(paint(DIM, "  Nothing releases from a red main."))

    orphans = sum(len(i.unlabelled_boxes) for i in issues)
    if orphans:
        out.append("")
        out.append(paint(DIM, f"  not checked: {orphans} × {UNLABELLED[0]}."))
        out.append(paint(DIM, f"  {UNLABELLED[1]}"))
    return "\n".join(out), len(waiting)
