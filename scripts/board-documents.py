#!/usr/bin/env python3
"""board-documents.py — which documents are process documents.

    board-documents.py process < path-list   # print the process documents among them
    board-documents.py list                  # print every process document

The list is `scripts/board/documents.py`'s. The pre-commit hook asks this
before committing one on a project branch, instead of keeping its own (#421).
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board import documents  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv == ["process"]:
        for path in documents.process_documents(line.strip() for line in sys.stdin):
            print(path)
        return 0
    if argv == ["list"]:
        print("\n".join(documents.PROCESS_DOCUMENTS))
        return 0
    print(f"board-documents.py: unknown command: {' '.join(argv)}\n{__doc__}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
