"""R4 — is this issue complete for what it is and where it is.

Owner, 2026-09-17: *"One report should check the contents of each issue
against type and state/phase."*

Reports **met**, **missing** and **not checked** separately and never conflates
the last two. Twenty-eight obligations exist and twelve are enforced; a row
nothing can evidence must read as unchecked, because an obligation that reads
as satisfied when nothing looked is how a board drifts while every report
stays green.
"""

from __future__ import annotations

from collections import Counter, defaultdict

from .model import Issue, classify
from .obligations import Answer, Finding, assess
from .sources import Snapshot

BOLD, DIM, RED, AMBER, GREEN, OFF = (
    "\033[1m", "\033[2m", "\033[31m", "\033[33m", "\033[32m", "\033[0m"
)


def _mark(answer: Answer) -> str:
    return {
        Answer.MET: f"{GREEN}ok {OFF}",
        Answer.MISSING: f"{RED}!! {OFF}",
        Answer.NOT_CHECKED: f"{DIM}-- {OFF}",
    }[answer]


def issue_lines(issue: Issue, findings: list[Finding], verbose: bool) -> list[str]:
    missing = [f for f in findings if f.answer is Answer.MISSING]
    unchecked = [f for f in findings if f.answer is Answer.NOT_CHECKED]
    if not missing and not verbose:
        return []

    step = issue.step or "unset"
    head = (f"{BOLD}#{issue.number}{OFF} {issue.kind} at {step}"
            f"  {DIM}{issue.title[:52]}{OFF}")
    out = [head]
    for finding in findings if verbose else missing:
        out.append(f"    {_mark(finding.answer)} {finding.obligation.what}")
        if finding.answer is Answer.MISSING:
            out.append(f"       {DIM}{finding.obligation.why}{OFF}")
    if not verbose and unchecked:
        out.append(f"    {DIM}-- {len(unchecked)} not checked{OFF}")
    return out + [""]


def render(snapshot: Snapshot, only: int | None, verbose: bool) -> tuple[str, int]:
    """The report, and the number of issues with something missing."""
    issues = [classify(r) for r in snapshot.issues]
    if only is not None:
        issues = [i for i in issues if i.number == only]
        if not issues:
            return (f"#{only} is not an open issue in this snapshot", 0)

    lines: list[str] = []
    totals: Counter[Answer] = Counter()
    by_cell: dict[tuple[str, str], Counter] = defaultdict(Counter)
    failing = 0

    for issue in sorted(issues, key=lambda i: i.number):
        findings = assess(issue)
        for finding in findings:
            totals[finding.answer] += 1
            by_cell[(issue.kind, issue.step or "unset")][finding.answer] += 1
        if any(f.answer is Answer.MISSING for f in findings):
            failing += 1
        lines += issue_lines(issue, findings, verbose)

    header = [
        f"{BOLD}ISSUE COMPLETENESS{OFF}  {DIM}R4 — each issue against its type "
        f"and step{OFF}",
        f"{DIM}{len(issues)} issue(s), snapshot {snapshot.window:.1f}s wide, "
        f"{snapshot.pages} page(s){OFF}",
        "",
    ]
    if not lines:
        lines = [f"{GREEN}nothing missing{OFF}", ""]

    summary = [
        f"{BOLD}By type and step{OFF}  {DIM}a step always incomplete is a "
        f"pattern, not forty findings{OFF}",
    ]
    for (kind, step), counts in sorted(by_cell.items()):
        miss = counts[Answer.MISSING]
        mark = f"{RED}{miss} missing{OFF}" if miss else f"{GREEN}complete{OFF}"
        summary.append(
            f"  {kind:18} {step:32} {mark}"
            f"{DIM}, {counts[Answer.NOT_CHECKED]} not checked{OFF}"
        )

    tail = [
        "",
        f"{BOLD}Totals{OFF}  "
        f"{GREEN}{totals[Answer.MET]} met{OFF}  "
        f"{RED}{totals[Answer.MISSING]} missing{OFF}  "
        f"{DIM}{totals[Answer.NOT_CHECKED]} not checked{OFF}",
        f"{DIM}'not checked' is an obligation nothing can evidence yet. It is "
        f"not a pass.{OFF}",
    ]
    return ("\n".join(header + lines + summary + tail), failing)
