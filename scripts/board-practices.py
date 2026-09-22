#!/usr/bin/env python3
"""board-practices.py — R3: which programme activities are overdue.

    scripts/board-practices.py          # every activity, frequency and last actioned
    scripts/board-practices.py --json   # the same, machine-readable
    scripts/board-practices.py --exit-code  # non-zero when anything is overdue

Reads the register (`docs/3.8-programme-activities.md`) for what exists and
how often it is owed, and the log (`docs/programme-activity-log.csv`) for when
each was last done. Neither is inferred from an artefact's age — the owner,
2026-09-22: *"Deriving actions from the presence or absence of a document
seems fragile to me... we need a record of the activities we have done, or the
last date each one was done."*

**Two readers use this, not one.** The session-start hook runs it for Claude,
every session; `.github/workflows/programme-activities.yml` runs it weekly for
the owner, during an absence — the one gap the session-start report and
`board-actions.py` leave. Neither is the other's delivery mechanism; both read
the same two files.

Design: #407.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import os

ROOT = Path(__file__).resolve().parent.parent
# Overridable for the test, which reads a real table and a real CSV rather
# than stubbing the parser — the same reasoning `CI_STATUS` and `SYNC_PR_STATE`
# already use in merge-to-release.sh.
REGISTER = Path(os.environ.get("REGISTER_OVERRIDE") or ROOT / "docs" / "3.8-programme-activities.md")
LOG = Path(os.environ.get("LOG_OVERRIDE") or ROOT / "docs" / "programme-activity-log.csv")

_ROW = re.compile(
    r"^\|\s*`([\w-]+)`\s*\|([^|]*)\|\s*(\d+)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|",
    re.M,
)


@dataclass(frozen=True)
class Activity:
    id: str
    name: str
    frequency_days: int
    owner: str
    last: date | None

    @property
    def overdue_by(self) -> int | None:
        """Days past due. `None` for something never logged — a separate case
        from a number, because *never done* and *not yet due* must not read
        alike."""
        if self.last is None:
            return None
        return (date.today() - self.last).days - self.frequency_days


def register() -> list[tuple[str, str, int, str]]:
    """`(id, name, frequency_days, owner)` for every row in the table.

    Regex over the file rather than a markdown parser: the same shape
    `check-api-errors.py` and the roadmap generator already use for a table
    that is the source of truth. A row's other two columns (produces, ITIL
    practice) are for a human reading the document, not for this.
    """
    text = REGISTER.read_text()
    return [(m.group(1), m.group(2).strip(), int(m.group(3)), m.group(4).strip())
            for m in _ROW.finditer(text)]


def last_actioned() -> dict[str, date]:
    """The most recent logged date per activity id."""
    out: dict[str, date] = {}
    with LOG.open(newline="") as f:
        for row in csv.DictReader(f):
            try:
                when = date.fromisoformat(row["date"])
            except (KeyError, ValueError):
                continue
            activity = row.get("activity", "")
            if activity not in out or when > out[activity]:
                out[activity] = when
    return out


def activities() -> list[Activity]:
    logged = last_actioned()
    return [Activity(aid, name, freq, owner, logged.get(aid))
            for aid, name, freq, owner in register()]


def render(items: list[Activity]) -> str:
    lines = []
    for a in items:
        if a.last is None:
            status = "never logged"
        else:
            over = a.overdue_by
            status = (f"OVERDUE by {over}d (last {a.last.isoformat()}, every {a.frequency_days}d)"
                      if over is not None and over > 0
                      else f"due in {-over}d (last {a.last.isoformat()})")
        lines.append(f"  {a.id:<16} {status}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--exit-code", action="store_true",
                    help="exit 1 when anything is overdue or never logged")
    args = ap.parse_args()

    if not REGISTER.exists() or not LOG.exists():
        # `cannot tell`, never `nothing outstanding` — an unreadable source and
        # a clean run must not look the same.
        print("board-practices: cannot read the register or the log", file=sys.stderr)
        return 2

    items = activities()
    overdue = [a for a in items if a.last is None or (a.overdue_by or 0) > 0]

    if args.json:
        print(json.dumps([
            {"id": a.id, "name": a.name, "frequency_days": a.frequency_days,
             "owner": a.owner, "last": a.last.isoformat() if a.last else None,
             "overdue_by": a.overdue_by}
            for a in items
        ], indent=2))
    else:
        print("==> Programme activities, against docs/3.8")
        print(render(items))
        if overdue:
            print(f"\n  {len(overdue)} overdue or never logged.")

    return 1 if (args.exit_code and overdue) else 0


if __name__ == "__main__":
    sys.exit(main())
