#!/usr/bin/env bash
set -euo pipefail

# board-running-on.test.sh — what an environment is running, named. #383 R3.
#
# Preview ran PR #420's branch tip on 2026-09-26 and board-status.py said "up
# to date with main": true, because it had everything on main, and misleading,
# because it was not on main at all. A real history is built here rather than
# canned, because the answer is git's.

cd "$(dirname "$0")/.."
HERE="$(pwd)"
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT

(
  cd "$REPO"
  git init -q -b main .
  git config user.email t@example.com
  git config user.name test
  commit() { echo "$1" > f; git add f; git commit -q -m "$1"; git rev-parse --short HEAD; }
  A=$(commit a)
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q -b 415-x
  B=$(commit b)
  C=$(commit c)
  git update-ref refs/remotes/origin/415-x HEAD
  git checkout -q main
  D=$(commit d)
  git update-ref refs/remotes/origin/main HEAD
  printf '%s %s %s %s\n' "$A" "$B" "$C" "$D" > "$REPO/.shas"
)

python3 - "$REPO" "$HERE" <<'PY'
import os, sys
repo_dir, here = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
A, B, C, D = open(os.path.join(repo_dir, ".shas")).read().split()
os.chdir(repo_dir)
from board.repo import running_on, behind_main
from board.programme import branch_line

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       want {want!r}\n       got  {got!r}")
        failures += 1

prs = {"415-x": (420, "#415 Admin CLI, tests, countdown")}

print("on main")
where = running_on(f"0.8.2+{D}")
expect("main's tip is on main", True, where.on_main)
expect("and needs no second line", None, branch_line(where, prs))
expect("an older main commit is on main too", True, running_on(f"0.8.2+{A}").on_main)

print("on a branch")
where = running_on(f"0.8.2+{C}")
expect("a branch tip is not on main", False, where.on_main)
expect("the branch is named", "415-x", where.branch)
expect("as its latest commit", True, where.at_tip)
expect("with its pull request",
       "branch 415-x, its latest commit · PR #420 for #415 Admin CLI, tests, countdown",
       branch_line(where, prs))
older = running_on(f"0.8.2+{B}")
expect("an older commit on the branch says so", (False, "415-x", False),
       (older.on_main, older.branch, older.at_tip))
expect("a branch with no pull request is still named",
       "branch 415-x, its latest commit", branch_line(where, {}))

print("behind main as well")
expect("the branch lacks main's newest commit, and that is still counted",
       "1 change behind main", behind_main(f"0.8.2+{C}"))

print("nothing to go on")
expect("a version with no commit", None, running_on("0.8.2"))
expect("a commit this clone does not have", None, running_on("0.8.2+deadbee"))

if failures:
    print(f"{failures} failed")
    sys.exit(1)
print("all passed")
PY
