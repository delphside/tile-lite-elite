#!/usr/bin/env python3
"""board-pr-state.py — put every pull request on the board, and set `PR State`
from what GitHub already knows.

    scripts/programme/board/board-pr-state.py            # add what is missing, set what is wrong
    scripts/programme/board/board-pr-state.py --check    # report the drift and change nothing

The field is derived, never typed: if it disagrees with reviewDecision, the
field is wrong. The ladder is `sources.pr_state`; which pull requests need
adding or correcting, and why, is `scripts/programme/board/pr_sync.py`.

Refuses (exit 2) when:
  - the project has no `PR State` single-select field, or it cannot be read
    -> "board-pr-state: no 'PR State' field on the project — nothing to sync"
    An unreadable field and an absent one look the same from here, so a token
    that cannot see the project lands in this message too.
  - the pull requests or the board cannot be read
    -> "board-pr-state: could not read ..."

Reports drift (exit 1) from --check when:
  - a pull request is not on the board
    -> "  #N is not on the board — should be '<state>'"
  - the board's value disagrees with GitHub's
    -> "  #N says '<have>', GitHub says '<want>'"
  - an open pull request requests nobody's review, which leaves it waiting on
    nobody; the command to request one is printed, never run
    -> "  #N is open and requests nobody's review — it is waiting on nobody"

Warns without failing (the run continues, exit unaffected) when:
  - an item could not be added to the board
    -> "  #N could not be added"
    A failed add is not counted as added, and nothing is set on it.
  - a value could not be set
    -> "  #N could not be set to '<state>' (...)"

Exit 0 from --check when the board agrees with GitHub, and from the plain form
once it has added and corrected what it found. PR_REVIEWER names the login the
requests-nobody hint suggests (default SteveStyle).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import pr_sync  # noqa: E402
from board.model import PR_STATE  # noqa: E402
from board.sources import (Unavailable, add_to_project,  # noqa: E402
                           board_pull_requests, project_field_options,
                           pull_requests, set_project_field)

NAME = "board-pr-state"


def _print(tally: pr_sync.Tally) -> None:
    # Flushed line by line, so under `2>&1` (as verify.sh reads it) the lines
    # come out in the order they were said.
    for err, text in tally.lines:
        print(text, file=sys.stderr if err else sys.stdout, flush=True)


def main(argv: list[str]) -> int:
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    checking = "--check" in argv
    reviewer = os.environ.get("PR_REVIEWER") or "SteveStyle"
    try:
        project_field_options(PR_STATE)
    except Unavailable:
        print(f"{NAME}: no '{PR_STATE}' field on the project — nothing to sync",
              file=sys.stderr)
        return 2
    try:
        drifts = pr_sync.plan(pull_requests(), board_pull_requests(PR_STATE))
    except Unavailable as exc:
        print(f"{NAME}: could not read the pull requests or the board ({exc})",
              file=sys.stderr)
        return 2

    if checking:
        tally = pr_sync.check(drifts, reviewer)
        _print(tally)
        if not tally.drifted and not tally.unrequested:
            print(f"{NAME}: the board agrees with GitHub")
            return 0
        print(f"{NAME}: {tally.drifted} pull request(s) drifted, "
              f"{tally.unrequested} requesting nobody")
        return 1

    tally = pr_sync.apply(drifts, add_to_project,
                          lambda item, value: set_project_field(item, PR_STATE, value),
                          reviewer)
    _print(tally)
    print(f"{NAME}: {tally.added} added, {tally.corrected} corrected, "
          f"{tally.unrequested} requesting nobody")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
