#!/usr/bin/env python3
"""board-refs.py — which issue a commit, a message or a branch names.

    board-refs.py named < message-file      # issues a message names, one per line
    board-refs.py branch <name>              # the issue a branch is for, or nothing
    board-refs.py count <rev> <N>            # commits in <rev> naming #N
    board-refs.py numbers <rev>              # every issue named in <rev>, ascending
    board-refs.py commits <rev> <N>          # the commits in <rev> naming #N
    board-refs.py -C <dir> ...               # against the repository at <dir>

<rev> is anything `git log` takes: a ref, or a range like A..B. Merge commits
count: a trailer on a merge is one somebody wrote.

The rule itself is `scripts/programme/board/refs.py`'s: `Refs #N` or `Closes #N`,
capitalised. This is the command the bash tooling calls instead of keeping a
copy of it (#421). An unknown <rev> answers as though nothing names anything,
and exits 0.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import refs  # noqa: E402
from board.repo import messages  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "-C":
        os.chdir(argv[1])
        argv = argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    if cmd == "named" and not args:
        for n in sorted(refs.named(sys.stdin.read())):
            print(n)
    elif cmd == "branch" and len(args) == 1:
        issue = refs.branch_issue(args[0])
        if issue is not None:
            print(issue)
    elif cmd == "count" and len(args) == 2:
        print(sum(1 for _, body in messages(args[0]) if int(args[1]) in refs.named(body)))
    elif cmd == "numbers" and len(args) == 1:
        for n in sorted(set().union(*(refs.named(b) for _, b in messages(args[0])))):
            print(n)
    elif cmd == "commits" and len(args) == 2:
        for sha, body in messages(args[0]):
            if int(args[1]) in refs.named(body):
                print(sha)
    else:
        print(f"board-refs.py: unknown or malformed command: {' '.join(argv)}\n{__doc__}",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
