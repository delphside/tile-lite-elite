#!/usr/bin/env python3
"""board-stage.py — give a new requirement its Stage.

    scripts/board-stage.py <number>...            # what the issue workflow runs
    scripts/board-stage.py <number>... --dry-run  # say what it would do

Run by `.github/workflows/requirement-stage.yml` when an issue is opened or
typed. A requirement with no Stage reads as Triage everywhere in the model,
but the board shows it as blank, so a view filtered by Stage hides it. This
writes the Stage the model already reads. Which issues get one, and which
value, is `Requirement.stage_to_record` in `scripts/board/model.py`.

Never overwrites a Stage that is set. Exits 1 when the board cannot be read
or written, so a failed run shows in the workflow's log.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.model import classify  # noqa: E402
from board.sources import Unavailable, issues_in_full, set_field  # noqa: E402


def main(argv: list[str]) -> int:
    numbers = [int(a) for a in argv if a.isdigit()]
    if not numbers or "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    dry = "--dry-run" in argv
    try:
        issues = {n: classify(r) for n, r in issues_in_full(numbers).items()}
    except Unavailable as exc:
        print(f"board-stage: could not read the board ({exc})")
        return 1
    failed = False
    for number in numbers:
        issue = issues.get(number)
        stage = getattr(issue, "stage_to_record", None)
        if issue is None:
            print(f"board-stage: #{number} not found")
            failed = True
            continue
        if stage is None:
            print(f"board-stage: #{number} needs no Stage written")
            continue
        if dry:
            print(f"board-stage: would set #{number} {issue.title}: Stage {stage}")
            continue
        try:
            set_field(number, "Stage", stage)
            print(f"board-stage: #{number} {issue.title}: Stage {stage}")
        except Unavailable as exc:
            print(f"board-stage: could not set #{number}'s Stage ({exc})")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
