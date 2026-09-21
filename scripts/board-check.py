#!/usr/bin/env python3
"""board-check.py — R4: is each issue complete for its type and step?

The first piece of the board model, built beside the existing scripts rather
than replacing them. Nothing retires until the model is trusted.

    scripts/board-check.py                 # every open issue with something missing
    scripts/board-check.py --all           # every obligation, met or not
    scripts/board-check.py 383             # one issue
    scripts/board-check.py --exit-code     # non-zero if anything is missing

Reports and does not refuse. Twenty-eight obligations exist and twelve are
enforceable today; the rest answer **not checked**, which is not a pass. A
gate refuses and work stops; a check reports and a person decides, and this is
the second until the diff against the old scripts has been quiet.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.report import render          # noqa: E402
from board.branches import check as check_branches
from board.branches import render as render_branches
from board.branches import named_numbers
from board.sources import (Unavailable, fetch, issues_by_number,
                           remote_branches)  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("issue", nargs="?", type=int, default=None,
                    help="one issue number; omit for the whole board")
    ap.add_argument("--all", action="store_true",
                    help="show every obligation, not only what is missing")
    ap.add_argument("--closed", action="store_true",
                    help="read closed issues instead of open ones")
    ap.add_argument("--exit-code", action="store_true",
                    help="exit non-zero when something is missing")
    ap.add_argument("--no-colour", action="store_true",
                    help="plain text, for a caller that captures the output")
    args = ap.parse_args(argv)

    started = time.time()
    try:
        snapshot = fetch(states="CLOSED" if args.closed else "OPEN")
    except Unavailable as exc:
        # A source that did not answer is not a clean bill of health.
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    text, failing = render(snapshot, args.issue, args.all)

    # **R9, and only for the whole board.** Asked about one issue, the branches
    # are not the question; printing them anyway is how a report starts being
    # skimmed. A branch source that cannot answer is reported, not silently
    # treated as no branches -- the distinction the whole module keeps.
    if args.issue is None:
        try:
            names = remote_branches()
            board = {i.number: i for i in snapshot.issues}
            # Only the numbers the branches name, and only those the open
            # snapshot does not already hold. Fetching the whole closed board
            # for this took the report from 3.4s to 15s.
            wanted = [n for n in named_numbers(names) if n not in board]
            board.update(issues_by_number(wanted))
            found = check_branches(names, board)
            text += "\n\n" + render_branches(found, len(names))
            failing = failing or bool(found)
        except Unavailable as exc:
            text += f"\n\n  branches: cannot say — {exc}"

    # Stripped at the boundary rather than threaded through the renderer:
    # nineteen call sites would each have to remember, and one that forgot
    # would put escape codes into a caller's captured output.
    if args.no_colour:
        text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    print(text)
    print(f"\033[2mfetched in {snapshot.window:.1f}s, "
          f"reported in {time.time() - started:.1f}s total\033[0m")

    return 1 if (args.exit_code and failing) else 0


if __name__ == "__main__":
    raise SystemExit(main())
