#!/usr/bin/env python3
"""board-digest.py — D54's weekly digest.

    scripts/programme/board/board-digest.py                      # the last seven days, printed
    scripts/programme/board/board-digest.py --since <tag>        # since a tag, sha or date
    scripts/programme/board/board-digest.py --write              # <PROGRAMME_DIR>/records/2.4-weekly-digest/PRG_WD_<year>_W<week>.md

The brake's two measures, what landed, what was deleted, and anything decided
that the owner might have decided differently. #382 asked for an issue comment
a week; since 2026-09-27 it is a report file, the `weekly-digest` activity in
the programme's docs/1.4, under CLAUDE.md's rule for reports the programme produces on a
cadence. Owner: the file, not the comment, so the series outlives #382.

Three of the four parts are derived from git and the board. The fourth is a
judgement about someone else's preferences, so `--decided` supplies it and an
empty one says it was not written rather than that there was nothing.

The register is read from the pinned `programme/` submodule and the digests are
written to the live checkout (`PROGRAMME_DIR`), both through `records.py`.

Design: programme/records/2.5-changes/programme-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import records  # noqa: E402
from board.digest import build, draft, notes_for_write, render, report_code  # noqa: E402
from board.sources import Unavailable, fetch     # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default=str(date.today() - timedelta(days=7)),
                    help="tag, sha or YYYY-MM-DD (default: seven days ago)")
    ap.add_argument("--decided", action="append", metavar="TEXT",
                    help="a judgement call the owner might have made "
                         "differently; repeatable")
    ap.add_argument("--write", action="store_true",
                    help="write it to records/2.4-weekly-digest/ in the live checkout for this ISO week")
    args = ap.parse_args(argv)

    # Before the board is fetched: no point asking GitHub for a digest that has
    # nowhere to go. Printing it needs only the register; writing needs the live checkout.
    reports = records.weekly_digests() if args.write else None

    try:
        # Pull requests are excluded: the share is about issues on the board.
        # Bodies and pull requests: what is waiting on the owner reads both.
        open_snapshot = fetch("OPEN", with_bodies=True, with_pull_requests=True)
        # Bodies, for each closed issue's lessons learnt.
        closed = fetch("CLOSED", with_bodies=True, with_pull_requests=False)
    except Unavailable as exc:
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    registers = records.activity_register().read_text()
    digest = build(open_snapshot, closed, since=args.since, registers=registers,
                   memory_repo=Path.home() / "claude-memory")
    text = render(digest, args.decided)

    if args.write:
        # Named for the ISO week it closes, like a capacity plan names its month.
        today = date.today()
        code = report_code(today)
        path = reports / f"{code}.md"
        notes = notes_for_write(path.read_text() if path.exists() else None)
        if notes is None:
            print(f"board-digest: {path.relative_to(records.live())} is written; "
                  "delete it to regenerate one still in review", file=sys.stderr)
            return 1
        text = render(digest, args.decided, notes)
        path.parent.mkdir(parents=True, exist_ok=True)
        heading, rest = text.split("\n", 1)
        path.write_text(f"{heading}\n\n`{code}`\n{rest}\n")
        # And next week's draft, for the notes (the programme's docs/1.4).
        ncode = report_code(today + timedelta(days=7))
        npath = reports / f"{ncode}.md"
        if not npath.exists():
            npath.write_text(draft(ncode, (today + timedelta(days=1)).isoformat()))
        print(path.relative_to(records.live()))
        print(npath.relative_to(records.live()))
        return 0

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
