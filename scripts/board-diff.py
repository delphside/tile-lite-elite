#!/usr/bin/env python3
"""board-diff.py — R7: where the model and the scripts disagree.

    scripts/board-diff.py               # every disagreement
    scripts/board-diff.py --exit-code   # non-zero if any

Temporary, for the duration of the move to the board model. Empty is the goal.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board import repo                        # noqa: E402
from board.diff import render                 # noqa: E402
from board.sources import Unavailable, fetch  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exit-code", action="store_true")
    args = ap.parse_args(argv)
    try:
        snapshot = fetch(states="OPEN", with_bodies=False)
    except Unavailable as exc:
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2
    text, count = render(snapshot, repo.commits())
    print(text)
    return 1 if (args.exit_code and count) else 0


if __name__ == "__main__":
    raise SystemExit(main())
