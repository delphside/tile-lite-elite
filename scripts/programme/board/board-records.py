#!/usr/bin/env python3
"""board-records.py — where the programme's files are, for shell scripts.

    scripts/programme/board/board-records.py live       # the live checkout, for records
    scripts/programme/board/board-records.py generic    # the pinned submodule

One definition of the default and the override (`records.py`), asked rather
than repeated in each shell script. A missing live checkout prints the path
tried and exits non-zero.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import records  # noqa: E402


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args == ["live"]:
        print(records.live())
    elif args == ["generic"]:
        print(records.generic())
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
