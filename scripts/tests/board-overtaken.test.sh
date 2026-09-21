#!/usr/bin/env bash
set -euo pipefail

# board-overtaken.test.sh — a shipped project still open when the next release
# went out. Moved from verify.sh's check_reviews.
#
# The rule that matters is which clock: entering Post-deployment, not the phase
# it sits in now. A project that wrote its review promptly and then sat unclosed
# for a month has still been open a month.

cd "$(dirname "$0")/.."
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, classify
from board.overtaken import candidates, check, render

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

def proj(n, phase, parent=None):
    return classify(RawIssue(n, f"project {n}", "OPEN", "", "Project",
                             {"Phase": phase, "Route": "Production Release"},
                             (), parent, None, frozenset()))

RELEASE = 1_000_000.0
BEFORE, AFTER = RELEASE - 86_400, RELEASE + 86_400

print("which projects are worth dating")
issues = [proj(1, "Post-deployment", parent=9), proj(2, "Project Closedown", parent=9),
          proj(3, "Development", parent=9), proj(4, "Scope", parent=9)]
expect("both shipped phases, and no others", [1, 2],
       [i.number for i in candidates(issues)])

print()
print("the clock is entering Post-deployment")
# #2 is at Project Closedown now; what counts is when it shipped.
found = check(issues, {1: AFTER, 2: BEFORE}, RELEASE)
expect("one overtaken", [2], [o.number for o in found])
expect("and it is named at the phase it sits in now", "Project Closedown",
       found[0].step)

print()
print("what is deliberately not a finding")
expect("no release yet, so nothing can have been overtaken", 0,
       len(check(issues, {1: BEFORE, 2: BEFORE}, None)))
# Set before the field existed, or moved by a migration. Unknown must not read
# as late.
expect("a project with no date at all", 0, len(check(issues, {}, RELEASE)))
expect("one that shipped after the release", 0,
       len(check(issues, {1: AFTER, 2: AFTER}, RELEASE)))

print()
print("rendering")
expect("a clean run says so", True,
       "nothing shipped past" in render((), colour=False))
expect("a finding names the issue", True,
       "#2" in render(check(issues, {2: BEFORE}, RELEASE), colour=False))

print()
if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all overtaken cases hold")
PY
