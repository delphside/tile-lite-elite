#!/usr/bin/env python3
"""board-context.py — R10 of #383: write the context header on every open project.

    scripts/board-context.py              # show which headers would change
    scripts/board-context.py 400          # print the header #400 should carry
    scripts/board-context.py --write      # rewrite every stale header
    scripts/board-context.py --write 414  # just that one family's members

The header is the parent and its work packages, each with phase, route,
milestone and open pull request, then what the family waits on and is needed
by. It is identical on every member of a family, and generated from the board
model, so it is never edited by hand: `board-check.py` reports one that is
missing or stale, and this rewrites it.

Refuses (exit 2) when GitHub cannot be read, rather than writing headers from a
partial board.

Design: docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.context import (family, family_root, headers,  # noqa: E402
                           wanted_titles, with_header, current)
from board.model import classify  # noqa: E402
from board.sources import REPO, OWNER, Unavailable, fetch, issues_by_number  # noqa: E402


def load():
    snapshot = fetch()
    board = {i.number: i for i in (classify(r) for r in snapshot.issues)}
    titles = {n: i.title for n, i in board.items()}
    missing = [n for n in wanted_titles(list(board.values())) if n not in titles]
    titles.update({n: r.title for n, r in issues_by_number(missing).items()})
    return board, titles


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("issue", nargs="?", type=int,
                    help="one issue; with --write, its whole family")
    ap.add_argument("--write", action="store_true",
                    help="rewrite the headers that are missing or stale")
    args = ap.parse_args(argv)

    try:
        board, titles = load()
    except Unavailable as exc:
        print(f"cannot say: {exc}", file=sys.stderr)
        return 2

    wanted = headers(board, titles)
    if args.issue is not None:
        if args.issue not in wanted:
            print(f"#{args.issue} is not an open project", file=sys.stderr)
            return 1
        if not args.write:
            print(wanted[args.issue])
            return 0
        root = family_root(board[args.issue], board)
        targets = [m.number for m in family(root, board)]
    else:
        targets = sorted(wanted)

    changed = [n for n in targets if current(board[n]) != wanted[n]]
    if not args.write:
        for n in changed:
            print(f"#{n} {board[n].title}")
        print(f"{len(changed)} of {len(targets)} would change", file=sys.stderr)
        return 0

    for n in changed:
        body = with_header(board[n].body, wanted[n])
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(body)
        # `--body-file`, never `--body`: the shell would evaluate backticks.
        out = subprocess.run(["gh", "issue", "edit", str(n), "-R", f"{OWNER}/{REPO}",
                              "--body-file", f.name], capture_output=True, text=True)
        Path(f.name).unlink(missing_ok=True)
        if out.returncode != 0:
            print(f"#{n}: {out.stderr.strip()}", file=sys.stderr)
            return 1
        print(f"#{n} written")
    print(f"{len(changed)} written", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
