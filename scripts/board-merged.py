#!/usr/bin/env python3
"""board-merged.py — move a merged work package's Phase on.

    scripts/board-merged.py <branch>            # what `.githooks/post-merge` runs
    scripts/board-merged.py <branch> --dry-run  # say what it would do

Run by the post-merge hook when a project branch fast-forwards into `main`.
Finds the work package the branch delivered, from its pull request as well as
the branch's own number, and moves its Phase from Development or User testing
to Deployment (a Production Release, which waits for its release) or
Post-deployment (a Repository Change, which the merge delivered).

Never fails the merge: anything it cannot do is printed, with what to set by
hand, and it exits 0. The merge has already happened by the time it runs.

Design: scripts/board/merge.py.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.merge import moves, named  # noqa: E402
from board.model import classify  # noqa: E402
from board.sources import (Unavailable, issues_in_full,  # noqa: E402
                           pull_request_for, set_field)


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    branch, dry = argv[0], "--dry-run" in argv[1:]
    try:
        pr = pull_request_for(branch)
        candidates = named(branch, *(pr[1:] if pr else ()))
        issues = {n: classify(r) for n, r in issues_in_full(candidates).items()}
        todo = moves(candidates, issues)
    except Unavailable as exc:
        print(f"post-merge: could not read the board ({exc}); "
              f"set the work package's Phase by hand")
        return 0
    if not todo:
        print(f"post-merge: {branch} moves no work package's Phase")
        return 0
    for number, was, to in todo:
        title = issues[number].title
        if dry:
            print(f"post-merge: would move #{number} {title}: {was} -> {to}")
            continue
        try:
            set_field(number, "Phase", to)
            print(f"post-merge: #{number} {title}: {was} -> {to}")
        except Unavailable as exc:
            print(f"post-merge: could not set #{number}'s Phase to {to} ({exc}); set it by hand")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
