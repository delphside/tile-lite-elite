#!/usr/bin/env python3
"""board-shipping.py — what reaches the image.

    board-shipping.py commit <sha>           # exit 0 if the commit reaches the image, 1 if not
    board-shipping.py range <base> <head>    # the same for the change between two commits
    board-shipping.py paths < path-list      # print the paths, of those given, that reach it
    board-shipping.py ships <sha>            # exit 0 if it reaches the image and is more than a version bump
    board-shipping.py version-bump --staged  # exit 0 if what is staged is only the app version moving
    board-shipping.py -C <dir> ...           # against the repository at <dir>

The rule is `scripts/programme/board/shipping.py`'s. This is the command the bash tooling
calls instead of keeping a copy of it: `shipping-paths.sh`'s functions, the
pre-commit hook, `deploy.sh`, `verify.sh` and CI (#421). An unknown commit
changed nothing, so it answers 1.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import shipping  # noqa: E402
from board.repo import (changed_paths, changed_paths_between,  # noqa: E402
                        staged, version_lines)


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "-C":
        os.chdir(argv[1])
        argv = argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, args = argv[0], argv[1:]
    if cmd == "commit" and len(args) == 1:
        return 0 if shipping.touches_image(changed_paths(args[0])) else 1
    if cmd == "range" and len(args) == 2:
        return 0 if shipping.touches_image(changed_paths_between(*args)) else 1
    if cmd == "ships" and len(args) == 1:
        return 0 if shipping.ships(changed_paths(args[0]), version_lines(args[0])) else 1
    if cmd == "version-bump" and args == ["--staged"]:
        return 0 if shipping.version_bump_only(*staged()) else 1
    if cmd == "paths" and not args:
        for path in shipping.image_paths(line.strip() for line in sys.stdin):
            print(path)
        return 0
    print(f"board-shipping.py: unknown or malformed command: {' '.join(argv)}\n{__doc__}",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
