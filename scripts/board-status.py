#!/usr/bin/env python3
"""board-status.py — R3: where the programme stands.

    scripts/board-status.py            # the four blocks
    scripts/board-status.py --fetch    # git fetch first, for accurate ancestry

What is in flight, what a release would ship, and what is behind — without
opening GitHub. Runs beside `status.sh` rather than replacing it, and a
difference between them is what the parallel run is for.

Three sources meet here: GitHub says what each change is, git says where it
got to, and `/health` says what is running. None of them alone can answer it.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board import repo                        # noqa: E402
from board.programme import render            # noqa: E402
from board.sources import Unavailable, fetch  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fetch", action="store_true",
                    help="git fetch first, so ancestry is accurate")
    ap.add_argument("--no-colour", action="store_true")
    args = ap.parse_args(argv)

    if args.fetch:
        subprocess.run(["git", "fetch", "--quiet", "origin"], check=False)

    started = time.time()
    try:
        # Bodies are needed: the post-deployment block counts boxes in one.
        snapshot = fetch(states="OPEN", with_bodies=True)
    except Unavailable as exc:
        # A source that did not answer is not an empty programme.
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    print(render(snapshot, repo.commits(), colour=not args.no_colour))
    print(f"\033[2mfetched in {snapshot.window:.1f}s, "
          f"reported in {time.time() - started:.1f}s total\033[0m")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
