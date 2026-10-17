#!/usr/bin/env python3
"""board-profile.py — the application's and the programme's facts, for shell scripts.

    board-profile.py get <key>            # one value; a list one item per line
    board-profile.py version app|api      # the version the tree holds now
    board-profile.py registers            # the registers a new script is named in, one path per line
    board-profile.py json-string <text>   # the text as a JSON string literal, for splicing into a jq filter
    board-profile.py -C <dir> ...         # against the application at <dir>

Keys are dotted. The first part says which file answers:

- `organisation`, `board`, `accounts`, `programme`, `records`: the programme file
  (`config/programme.toml`, from the pinned submodule; `PROGRAMME_CONFIG` replaces it);
- `profile`: the application's programme profile, in the live checkout
  (`profile.identity.repository`, `profile.environments`, `profile.records.3`);
- anything else: the application's technical profile, `programme.toml` at its
  root (`PROGRAMME_PROFILE` replaces it): `versions.stamp`, `release.tag_prefix`.

A list of tables (`hooks.pre_commit`) prints one block per table: a `name=value`
line for each key, then an empty line, so a reader takes each value by its name. A missing file or key, or a key a `hooks.*` block
does not know, stops with a message naming it and exits 70
(`profile.EXIT_PROFILE_ERROR`, which no caller may read as "no"); nothing here has a built-in answer. `version` prints nothing, and
exits 0, when the tree holds no such version (a repository that is not the
application's).

The loader is `scripts/programme/board/profile.py` (#485).
"""

from __future__ import annotations

import os
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from board import profile  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "-C":
        os.chdir(argv[1])
        argv = argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "get" and len(argv) == 2:
        for line in profile.render(profile.lookup(argv[1])):
            print(line)
        return 0
    if argv[0] == "json-string" and len(argv) == 2:
        print(json.dumps(argv[1]))
        return 0
    if argv == ["registers"]:
        for line in profile.tools_registers():
            print(line)
        return 0
    if argv[0] == "version" and len(argv) == 2 and argv[1] in ("app", "api"):
        found = profile.current_version(argv[1])
        if found:
            print(found)
        return 0
    print(f"board-profile.py: unknown or malformed command: {' '.join(argv)}\n{__doc__}",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
