"""R3: where the programme stands.

Answers, without opening GitHub: what is in flight, what would a release ship,
and what is behind. Four blocks, in the order the questions get asked.

**The separation in block 2 is the whole value.** A Repository Change is live
at merge and must not appear under *would ship*; a parent carries no route and
must not appear under *cannot say*. Both were wrong before this design, and
both were wrong the same way — a consumer reading the answer off the type when
the Route is what carries it.

Three sources meet here and none of them is the board alone: GitHub says what
each change is, git says where it got to, and `/health` says what is running.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import repo
from .model import ParentProject, Requirement, StandaloneProject, WorkPackage, classify
from .sources import Snapshot

DELIVERING = (WorkPackage, StandaloneProject)

# Owner's threshold, #382 D54: re-read a document once this much of it has
# changed since it was last read whole.
REVIEW_THRESHOLD = int(os.environ.get("REVIEW_THRESHOLD_PERCENT", "45"))

STAMP = re.compile(r"Reviewed whole at `([0-9a-f]+)`")


def _rehearsal_url() -> str:
    """From the file that defines it, never a second copy.

    Read in a subshell: that file exports variables meant for `deploy.sh`, and
    before #24 its URL variable was called `PROD_URL` — sourcing it directly
    overwrote production's URL with the rehearsal one, and the report showed
    the rehearsal host on both lines. It looked plausible, because the two are
    usually on the same commit.
    """
    script = Path(__file__).resolve().parent.parent / "rehearsal-target.sh"
    if not script.exists():
        return ""
    out = subprocess.run(["bash", "-c", f'. "{script}" >/dev/null 2>&1; printf "%s" "$TARGET_URL"'],
                         capture_output=True, text=True)
    return out.stdout.strip()


def branch_line(where: "repo.RunningOn | None", prs: dict[str, tuple[int, str]]) -> str | None:
    """The second line under an environment not running `main`, or None."""
    if where is None or where.on_main:
        return None
    if where.branch is None:
        return "not on main, and on no branch pushed here"
    tip = "its latest commit" if where.at_tip else "an older commit on it"
    line = f"branch {where.branch}, {tip}"
    if where.branch in prs:
        number, title = prs[where.branch]
        # A pull request is titled for its work package, "#415 Admin CLI…".
        joiner = " for " if re.match(r"#\d+ ", title) else " "
        line += f" · PR #{number}{joiner}{title}"
    return line


def environments() -> list[tuple[str, str, str, str]]:
    urls = [
        ("production", os.environ.get("PROD_URL", "https://tileliteelite.com"),
         "what users have"),
        ("rehearsal", os.environ.get("REHEARSAL_URL") or _rehearsal_url(),
         "what the release gate checks"),
        ("preview", os.environ.get("PREVIEW_URL")
         or os.environ.get("STAGING_URL", "http://localhost:8081"),
         "what you last looked at"),
    ]
    rows = []
    for name, url, meaning in urls:
        version = repo.live_version(url) if url else None
        # "did not answer" is not "not deployed"; the report must not merge them.
        where = repo.running_on(version)
        behind = repo.behind_main(version)
        if where is not None and not where.on_main:
            # Not on main, and possibly also missing commits that are.
            behind = ("not on main" if behind.startswith("up to date")
                      else f"not on main, {behind}")
        rows.append((name, version or "did not answer", behind, meaning))
    return rows


# Where the board would have to be for the commits to make sense. Only the
# clearly-impossible pairs are listed: the point is to catch a contradiction,
# not to police every ordering.
EARLY = ("Scope", "Q1", "Q2", "Q3", "Design and Test Approach")


@dataclass(frozen=True)
class Change:
    number: int
    title: str
    kind: str
    route: str | None
    milestone: str | None
    state: str
    phase: str | None
    note: str = ""

    @property
    def disagrees(self) -> bool:
        """The commits and the board cannot both be right.

        Only states that actually imply the work landed count. A
        *mentioned before prod-0.8.0* row is an old commit naming the issue in
        passing, which `Refs #N` explicitly permits — treating that as a
        contradiction reported four changes as disagreeing with the board when
        the derivation was what was wrong. Owner, 2026-09-18: *"Refs #N does
        not imply anything specific. Closes #N does."*
        """
        return (self.state.startswith("released")
                or self.state in ("closed by a commit on main", "merged",
                                  "merged, awaiting release")) \
            and self.phase in EARLY


def changes(snapshot: Snapshot, got: repo.Commits) -> list[Change]:
    """Every delivery, with where it got to. Parents and requirements are not
    deliveries and carry no route, so they are not asked for one."""
    out = []
    branches = repo.branches()
    shipped = got.shipped_milestones()
    for raw in snapshot.issues:
        issue = classify(raw)
        if not isinstance(issue, DELIVERING):
            continue
        route = issue.field("Route")
        state = got.state_of(issue.number,
                             live_at_merge=route != "Production Release",
                             milestone=issue.raw.milestone, shipped=shipped)
        if state == "not started" and issue.number in branches:
            state = "branch only"

        # **A package built before it existed carries its parent's number.**
        # #373 was split out of #297 after `1036e1c` had landed saying
        # `Refs #297`, and no rewrite can fix that -- the commit is the one
        # being deployed. verify.sh settled the rule (#375): do NOT count the
        # parent's commits as the package's, which would make every package of
        # a parent look built. Say *where* the commits are and let the reader
        # judge.
        note = ""
        if state in ("not started", "branch only") and issue.parent:
            elsewhere = got.released.count(issue.parent) \
                + got.unreleased.count(issue.parent)
            if elsewhere:
                note = (f"no commits of its own; #{issue.parent} carries "
                        f"{elsewhere} — split out after they landed?")
        out.append(Change(issue.number, issue.title, issue.kind, route,
                          issue.raw.milestone, state, issue.step, note))
    return sorted(out, key=lambda c: (c.state, -c.number))


def documents_to_reread() -> tuple[list[tuple[str, int, str]], list[str]]:
    """Documents that have changed a lot since anybody read them whole."""
    flagged, unstamped = [], []
    root = Path(".")
    for doc in sorted(list(root.glob("docs/*.md")) + list(root.glob("docs/changes/*.md"))):
        text = doc.read_text(errors="replace")
        match = STAMP.search(text)
        if not match:
            unstamped.append(str(doc.relative_to("docs")) if doc.is_relative_to("docs")
                             else str(doc))
            continue
        stamp = match.group(1)
        numstat = repo._git("diff", "--numstat", f"{stamp}..origin/main", "--", str(doc))
        churn = sum(int(n) for line in numstat.splitlines()
                    for n in line.split()[:2] if n.isdigit())
        total = max(1, len(text.splitlines()))
        percent = churn * 100 // total
        if percent >= REVIEW_THRESHOLD:
            flagged.append((str(doc), percent, stamp))
    return sorted(flagged, key=lambda f: -f[1]), unstamped


def unanswered_checks(snapshot: Snapshot) -> list[tuple[int, str, int]]:
    """Deliveries live with post-deployment checks nobody has answered."""
    out = []
    for raw in snapshot.issues:
        issue = classify(raw)
        if not isinstance(issue, DELIVERING) or issue.step != "Post-deployment":
            continue
        open_boxes = issue.unticked_in("Post-deployment checks against requirements") \
            + issue.unticked_in("Post-deployment checks")
        if open_boxes:
            out.append((issue.number, issue.title, open_boxes))
    return out


BOLD, DIM, RED, RESET = "\033[1m", "\033[2m", "\033[31m", "\033[0m"

STATE_ORDER = ("in progress", "merged, awaiting release", "merged",
               "closed by a commit on main", "released", "branch only",
               "not started")


def render(snapshot: Snapshot, got: repo.Commits, colour: bool = True) -> str:
    def paint(code: str, text: str) -> str:
        return f"{code}{text}{RESET}" if colour else text

    out: list[str] = []

    out.append(paint(BOLD, "Environments"))
    prs = {i.raw.head_ref: (i.number, i.title) for i in
           (classify(r) for r in snapshot.issues)
           if i.kind == "PullRequest" and i.raw.head_ref and i.state == "OPEN"}
    for name, version, behind, meaning in environments():
        out.append(f"  {name:<12}{version:<20}{behind:<34}{paint(DIM, meaning)}")
        extra = branch_line(repo.running_on(version), prs)
        if extra:
            out.append(f"  {'':<12}{paint(DIM, extra)}")

    out.append("")
    out.append(paint(BOLD, "A release from main would ship"))
    every = changes(snapshot, got)
    shipping = [c for c in every if c.state == "merged, awaiting release"]
    already = [c for c in every if c.state in ("merged", "closed by a commit on main")]
    if shipping:
        for c in shipping:
            out.append(f"  #{c.number:<5}{c.milestone or 'no milestone':<14}{c.title[:60]}")
    else:
        out.append(paint(DIM, "  no delivery is waiting on a release"))
    if already:
        out.append("")
        out.append(paint(DIM, f"  and {len(already)} already live, reaching users at "
                              f"merge rather than at a release:"))
        for c in already:
            out.append(paint(DIM, f"    #{c.number} {c.title[:56]}"))
    if got.unreleased_total:
        carried = len({c.number for c in shipping + already})
        out.append("")
        out.append(paint(DIM, f"  {got.unreleased_total} changes sit on main since "
                              f"{got.last_tag}; {carried} of them carry an issue. "
                              "The rest are docs, tooling and version bumps."))

    out.append("")
    out.append(paint(BOLD, "Open changes"))
    shown = 0
    states = [s for s in STATE_ORDER if s != "released"]
    states += sorted({c.state for c in every
                      if c.state not in STATE_ORDER and not c.state.startswith("released")})
    for state in states:
        rows = [c for c in every if c.state == state]
        if not rows:
            continue
        out.append(paint(DIM, f"  {state}"))
        for c in rows:
            flag = paint(RED, "  ← board says " + (c.phase or "no phase")) if c.disagrees else ""
            out.append(f"    #{c.number:<5}{(c.phase or '-'):<26}{c.title[:48]}{flag}")
            if c.note:
                out.append(paint(DIM, f"          {c.note}"))
            shown += 1
    if not shown:
        out.append(paint(DIM, "  nothing open"))

    out.append("")
    out.append(paint(BOLD, "Behind"))
    behind_any = False

    red = repo.ci_red_on_main()
    if red:
        behind_any = True
        out.append(f"  CI is red on main: {red}")
        out.append(paint(DIM, "  Nothing releases from a red main, and it is "
                              "Claude's to fix rather than the owner's."))
        out.append("")

    disagreeing = [c for c in every if c.disagrees]
    if disagreeing:
        behind_any = True
        out.append(f"  {len(disagreeing)} change(s) where the commits and the board disagree.")
        for c in disagreeing:
            out.append(paint(DIM, f"    #{c.number} commits say {c.state}, "
                                  f"the board says {c.phase}"))
        out.append(paint(DIM, "  One of the two is out of date. `Refs #N` means work "
                              "touched the issue, so this is a claim that it merged."))

    unanswered = unanswered_checks(snapshot)
    if unanswered:
        behind_any = True
        out.append("")
        for number, title, count in unanswered:
            out.append(f"  #{number} {title[:52]} — {count} post-deployment check(s) unanswered")

    flagged, unstamped = documents_to_reread()
    if flagged:
        behind_any = True
        out.append("")
        for doc, percent, stamp in flagged:
            out.append(f"  {doc:<44}{percent}% changed since {stamp} — worth re-reading")
    if unstamped:
        out.append(paint(DIM, f"  {len(unstamped)} document(s) carry no "
                              "`Reviewed whole at` stamp, so nothing can say whether "
                              "they are stale."))

    if not behind_any:
        out.append(paint(DIM, "  nothing overdue"))
    return "\n".join(out)
