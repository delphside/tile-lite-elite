#!/usr/bin/env python3
"""board-digest.py — D54's weekly digest.

    scripts/board-digest.py                      # the last seven days
    scripts/board-digest.py --since prod-0.8.0   # since a tag, sha or date
    scripts/board-digest.py --post 382           # add it as a comment

What landed, what was deleted, the tooling share, and anything decided that
the owner might have decided differently. #382, the job spec: one issue
comment a week, and nothing per-change.

Three of the four parts are derived from git and the board. The fourth is a
judgement about someone else's preferences, so `--decided` supplies it and an
empty one says it was not written rather than that there was nothing.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.digest import build, render           # noqa: E402
from board.sources import Unavailable, fetch     # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default=str(date.today() - timedelta(days=7)),
                    help="tag, sha or YYYY-MM-DD (default: seven days ago)")
    ap.add_argument("--decided", action="append", metavar="TEXT",
                    help="a judgement call the owner might have made "
                         "differently; repeatable")
    ap.add_argument("--post", type=int, metavar="N",
                    help="post it as a comment on issue N")
    args = ap.parse_args(argv)

    try:
        # Pull requests are excluded: the share is about issues on the board.
        open_snapshot = fetch("OPEN", with_bodies=False, with_pull_requests=False)
        closed = fetch("CLOSED", with_bodies=False, with_pull_requests=False)
    except Unavailable as exc:
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    text = render(build(open_snapshot, closed, since=args.since), args.decided)

    if args.post:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write(text)
            path = fh.name
        out = subprocess.run(["gh", "issue", "comment", str(args.post),
                              "--body-file", path], capture_output=True, text=True)
        if out.returncode:
            print(f"could not post: {out.stderr.strip()[:200]}", file=sys.stderr)
            return 1
        print(out.stdout.strip())
        return 0

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
