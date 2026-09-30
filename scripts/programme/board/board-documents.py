#!/usr/bin/env python3
"""board-documents.py — which documents are the programme's and which the application's.

    board-documents.py programme < path-list    # print the programme's documents among them
    board-documents.py application < path-list  # print the application's documents among them
    board-documents.py kind PATH...              # print each path's kind, or `none`

The rule is `scripts/programme/board/documents.py`'s. The pre-commit hook asks this
before committing a programme document on a project branch, which it refuses,
or an application document on `main`, which it warns about (#421 R5).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import documents  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv in (["programme"], ["application"]):
        for path in documents.of_kind(argv[0], (line.strip() for line in sys.stdin)):
            print(path)
        return 0
    if argv[0] == "kind" and len(argv) > 1:
        for path in argv[1:]:
            print(f"{path}\t{documents.kind(path) or 'none'}")
        return 0
    print(f"board-documents.py: unknown command: {' '.join(argv)}\n{__doc__}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
