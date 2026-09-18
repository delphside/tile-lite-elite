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
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.report import render          # noqa: E402
from board.sources import Unavailable, fetch  # noqa: E402


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
    args = ap.parse_args(argv)

    started = time.time()
    try:
        snapshot = fetch(states="CLOSED" if args.closed else "OPEN")
    except Unavailable as exc:
        # A source that did not answer is not a clean bill of health.
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    text, failing = render(snapshot, args.issue, args.all)
    print(text)
    print(f"\033[2mfetched in {snapshot.window:.1f}s, "
          f"reported in {time.time() - started:.1f}s total\033[0m")

    return 1 if (args.exit_code and failing) else 0


if __name__ == "__main__":
    raise SystemExit(main())
