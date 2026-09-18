"""R7: where the model and the scripts disagree.

**Temporary, and it should say so.** Across the move to the board model, catch
any consumer that starts answering differently. Empty is the goal; a report
with a scheduled death should announce it in its own output.

The design (`model.md`) names three outcomes and only one of them is bad:

| the diff says | what it means |
| --- | --- |
| nothing | the model reproduces the old behaviour |
| a difference the model is **right** about | an old bug, now visible |
| a difference the model is **wrong** about | a defect caught before it gated anything |

**This is not optional caution.** The `Refs`/`Closes` error — an old commit
mentioning an issue in passing made it read as delivered — existed in
`status.sh` and was reproduced in `board-status.py`, and a diff of the two
would have shown the rows where they now differ the moment the model was
corrected. Comparing outputs is how a convention misread gets caught, because
neither side knows it is wrong.

**Compared as facts, not as text.** Both sides are reduced to one word per
issue, because the wording differs by design and a text diff would be all
noise.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import repo
from .model import StandaloneProject, WorkPackage, classify
from .sources import Snapshot

DELIVERING = (WorkPackage, StandaloneProject)

# `status.sh`'s own vocabulary, from docs/3.3 "The six types of change".
TYPES = r"tooling|functional|unclassified|defect fix|cosmetic|documentation"
ROW = re.compile(rf"^\s{{4}}(\d+)\s+.*?\b({TYPES})\s{{2,}}(.+?)\s*$")


def _bucket(text: str) -> str:
    """One word per issue, so the two vocabularies can be compared at all."""
    low = text.lower()
    if low.startswith("not started"):
        return "not started"
    if low.startswith("branched"):
        return "branch only"
    if low.startswith("in progress"):
        return "in progress"
    if low.startswith("released") or "actioned" in low:
        return "released"
    if low.startswith("mentioned"):
        return "mentioned only"
    if low.startswith("merged") or low.startswith("closed by"):
        return "merged"
    return low.split("·")[0].strip()


def from_status_sh(timeout: float = 300) -> dict[int, str]:
    """Run the script and read its Open changes table."""
    script = Path(__file__).resolve().parent.parent / "status.sh"
    out = subprocess.run(["bash", str(script)], capture_output=True, text=True,
                         timeout=timeout)
    found, inside = {}, False
    for line in out.stdout.splitlines():
        if line.startswith("==> Open changes"):
            inside = True
            continue
        if inside and line.startswith("==>"):
            break
        match = ROW.match(line) if inside else None
        if match:
            found[int(match.group(1))] = _bucket(match.group(3))
    return found


def from_model(snapshot: Snapshot, got: repo.Commits) -> dict[int, str]:
    shipped = got.shipped_milestones()
    out = {}
    for raw in snapshot.issues:
        issue = classify(raw)
        if not isinstance(issue, DELIVERING):
            continue
        route = issue.field("Route")
        out[issue.number] = _bucket(got.state_of(
            issue.number, live_at_merge=route != "Production Release",
            milestone=issue.raw.milestone, shipped=shipped))
    return out


@dataclass(frozen=True)
class Disagreement:
    number: int
    title: str
    script: str
    model: str


def compare(snapshot: Snapshot, got: repo.Commits) -> tuple[list[Disagreement], int]:
    """Disagreements, and how many issues both sides actually spoke about.

    Only issues **both** describe are compared. `status.sh` lists parents and
    requirements that the model does not call deliveries, and counting those
    as disagreements would bury the real ones under a definitional difference
    that is the point of the model rather than a defect in it.
    """
    script, model = from_status_sh(), from_model(snapshot, got)
    titles = {raw.number: raw.title for raw in snapshot.issues}
    both = sorted(set(script) & set(model))
    out = [Disagreement(n, titles.get(n, ""), script[n], model[n])
           for n in both if script[n] != model[n]]
    return out, len(both)


def render(snapshot: Snapshot, got: repo.Commits) -> tuple[str, int]:
    rows, compared = compare(snapshot, got)
    out = [f"R7 · model against status.sh — {compared} issue(s) both describe"]
    if not rows:
        out.append("  they agree on every one.")
    else:
        out.append("")
        for row in rows:
            out.append(f"  #{row.number} {row.title[:52]}")
            out.append(f"      status.sh: {row.script:<18} model: {row.model}")
    out.append("")
    out.append("  Temporary. This report is retired when the move to the model "
               "is complete;")
    out.append("  a difference the model is right about is an old bug made "
               "visible, not a fault.")
    return "\n".join(out), len(rows)
