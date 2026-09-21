#!/usr/bin/env python3
"""board-inbox.py — R2: what has been said and decided since you last looked.

    scripts/board-inbox.py            # the last seven days
    scripts/board-inbox.py 2          # a different window, in days

Replaces `inbox.sh`. It exists because a conversation only works if both sides
can see it -- owner, 2026-08-18, after replying to a comment and having to say
so out loud.

**Seven days by default**, not because a week is the natural rhythm but because
the current one will not last. Owner, same day: *"Right now I am working on this
most days, but that won't last forever."* A default sized for today's cadence
would be exactly wrong on the first day it changed.

**Stateless.** No "last read" file to go stale, drift between machines, or need
clearing when it is wrong. You pass the window.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.inbox import build, render                          # noqa: E402
from board.sources import Unavailable, comments_since, fetch   # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("days", nargs="?", type=int, default=7,
                        help="how many days back to look (default 7)")
    parser.add_argument("--no-colour", action="store_true")
    args = parser.parse_args()

    if args.days < 1:
        print("board-inbox: the window is a whole number of days, at least 1",
              file=sys.stderr)
        return 2

    since = (datetime.now(timezone.utc) - timedelta(days=args.days)) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")

    try:
        # Both states: a thread on a closed issue is still a thread, and the
        # events section is about issues that closed.
        # Pull requests too: a review comment names a PR, and without them the
        # thread arrives as a bare number. `inbox.sh` had the same blank,
        # because `gh issue list` does not return pull requests either.
        opened = fetch("OPEN", with_bodies=False, with_pull_requests=True,
                       pr_states="[OPEN, CLOSED, MERGED]")
        closed = fetch("CLOSED", with_bodies=False, with_pull_requests=False)
        remarks = comments_since(since)
    except Unavailable as exc:
        # Refuse rather than report a quiet week. `inbox.sh` reported nothing on
        # a day four issues opened and four closed, because a malformed call
        # failed into /dev/null and looked exactly like silence.
        print(f"board-inbox: {exc}", file=sys.stderr)
        return 1

    inbox = build(opened.issues + closed.issues, remarks, since)
    print(render(inbox, colour=not args.no_colour))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
