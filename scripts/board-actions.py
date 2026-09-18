#!/usr/bin/env python3
"""board-actions.py — R1: what needs the owner.

    scripts/board-actions.py              # what is waiting, longest-quiet first
    scripts/board-actions.py --exit-code  # non-zero if anything is waiting

Built beside `actions.py`, not in place of it, and the two answer different
questions: `actions.py` lists every outstanding action on the board, this lists
only what the owner has to do. A difference between them is expected and is the
point of running both — see the parallel-running section of the #383 design.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.sources import Unavailable, fetch  # noqa: E402
from board.turn import render                 # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exit-code", action="store_true",
                    help="exit non-zero when something is waiting on the owner")
    ap.add_argument("--no-colour", action="store_true")
    args = ap.parse_args(argv)

    started = time.time()
    try:
        # Bodies are needed: the user-testing source counts boxes in one.
        snapshot = fetch(states="OPEN", with_bodies=True)
    except Unavailable as exc:
        # A source that did not answer is not "nothing is waiting on you".
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    text, count = render(snapshot, colour=not args.no_colour)
    print(text)
    print(f"\033[2mfetched in {snapshot.window:.1f}s, "
          f"reported in {time.time() - started:.1f}s total\033[0m")
    return 1 if (args.exit_code and count) else 0


if __name__ == "__main__":
    raise SystemExit(main())
