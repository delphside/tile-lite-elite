#!/usr/bin/env python3
"""board-digest.py — D54's weekly digest.

    scripts/board-digest.py                      # the last seven days, printed
    scripts/board-digest.py --since prod-0.8.0   # since a tag, sha or date
    scripts/board-digest.py --write              # docs/reports/weekly_digest/TLE_WD_<year>_W<week>.md

The brake's two measures, what landed, what was deleted, and anything decided
that the owner might have decided differently. #382 asked for an issue comment
a week; since 2026-09-27 it is a report file, the `weekly-digest` activity in
docs/3.8, under CLAUDE.md's rule for reports the programme produces on a
cadence. Owner: the file, not the comment, so the series outlives #382.

Three of the four parts are derived from git and the board. The fourth is a
judgement about someone else's preferences, so `--decided` supplies it and an
empty one says it was not written rather than that there was nothing.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.digest import build, render           # noqa: E402
from board.sources import Unavailable, fetch     # noqa: E402

REPORTS = Path(__file__).resolve().parent.parent / "docs" / "reports" / "weekly_digest"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default=str(date.today() - timedelta(days=7)),
                    help="tag, sha or YYYY-MM-DD (default: seven days ago)")
    ap.add_argument("--decided", action="append", metavar="TEXT",
                    help="a judgement call the owner might have made "
                         "differently; repeatable")
    ap.add_argument("--write", action="store_true",
                    help="write it to docs/reports/weekly_digest/ for this ISO week")
    args = ap.parse_args(argv)

    try:
        # Pull requests are excluded: the share is about issues on the board.
        # Bodies and pull requests: what is waiting on the owner reads both.
        open_snapshot = fetch("OPEN", with_bodies=True, with_pull_requests=True)
        closed = fetch("CLOSED", with_bodies=False, with_pull_requests=False)
    except Unavailable as exc:
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    text = render(build(open_snapshot, closed, since=args.since), args.decided)

    if args.write:
        # Named for the ISO week it closes, like TLE_CP_2026_09 names its month.
        year, week, _ = date.today().isocalendar()
        code = f"TLE_WD_{year}_W{week:02d}"
        path = REPORTS / f"{code}.md"
        if path.exists():
            # A report records what was true at a moment and is never edited
            # afterwards (CLAUDE.md), so a second run in the same week refuses.
            print(f"board-digest: {path.relative_to(REPORTS.parents[2])} exists, "
                  "and a report is not rewritten", file=sys.stderr)
            return 1
        path.parent.mkdir(parents=True, exist_ok=True)
        heading, rest = text.split("\n", 1)
        path.write_text(f"{heading}\n\n`{code}`\n{rest}\n")
        print(path.relative_to(REPORTS.parents[2]))
        return 0

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
