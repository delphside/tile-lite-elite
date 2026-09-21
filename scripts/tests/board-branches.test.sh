#!/usr/bin/env bash
set -euo pipefail

# board-branches.test.sh — R9, folded in from #342.
#
# The relationship, not the naming. `.githooks/commit-msg` already compares the
# branch name against the commit trailer; what it cannot do is ask whether the
# issue they agree on is real, open, and a project. These are those three.

cd "$(dirname "$0")/.."
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.branches import check, render
from board.model import RawIssue

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

def issue(n, kind="Project", state="OPEN"):
    return RawIssue(n, f"issue {n}", state, "", kind, {}, (), None, None,
                    frozenset(), frozenset(), frozenset())

board = {
    214: issue(214),
    290: issue(290),
    342: issue(342, kind="Requirement"),
    395: issue(395, state="CLOSED"),
}

print("a branch naming an open project is fine")
expect("no finding", 0, len(check(["214-build-once"], board)))
expect("nor for the older issue- form", 0, len(check(["issue-290-dioxus"], board)))

print()
print("and the three that are not")
f = check(["999-invented"], board)
expect("an issue that does not exist", 1, len(f))
expect("says so", True, "does not exist" in f[0].says)

f = check(["395-packages"], board)
expect("a closed project", 1, len(f))
expect("says to delete it once its release shipped", True, "closed" in f[0].says)

f = check(["342-branch-check"], board)
expect("a requirement rather than a project", 1, len(f))
expect("cites the rule", True, "docs/3.6" in f[0].says)

print()
print("what is deliberately not a finding")
# A rule about naming would refuse these, and #342 is about the relationship.
expect("main", 0, len(check(["main"], board)))
expect("a release branch", 0, len(check(["release/0.8.1"], board)))
expect("a branch naming no issue at all", 0, len(check(["spike-wasm-sizes"], board)))

print()
print("named_numbers, which lets a caller fetch only what it needs")
from board.branches import named_numbers
expect("the numbers, deduplicated and sorted", (214, 290),
       named_numbers(["290-dioxus-07", "214-build-once", "214-again"]))
expect("main and release branches are not numbers", (),
       named_numbers(["main", "release/0.8.1", "spike"]))

print()
print("rendering")
expect("a clean run says how many it looked at", True,
       "2 branch(es)" in render((), 2, colour=False))
expect("a finding names the branch", True,
       "999-invented" in render(check(["999-invented"], board), 1, colour=False))

print()
if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all branch cases hold")
PY
