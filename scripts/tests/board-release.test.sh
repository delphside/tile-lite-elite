#!/usr/bin/env bash
set -euo pipefail

# board-release.test.sh — what a milestone still owes, moved from verify.sh's
# check_approach.
#
# A release question rather than a per-issue one: board-check.py's obligations
# ask whether a delivery owes a test approach at its step; this asks whether the
# tests the projects in *this release* said they would run have been run.

cd "$(dirname "$0")/.."
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue, classify
from board.release import outstanding, render

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

APPROACH = """## Test approach

### Functional user tests — Preview

%s

### Technical tests — Rehearsal

%s
"""

def wp(n, preview, rehearsal, milestone="0.8.2", subs=()):
    return classify(RawIssue(n, f"wp {n}", "OPEN", APPROACH % (preview, rehearsal),
                             "Project", {"Phase": "Development", "Route": "x"},
                             subs, 9 if not subs else None, milestone, frozenset()))

print("what is outstanding")
done = wp(1, "- [x] **Claude** — looked at it", "- [x] **Claude** — ran it")
half = wp(2, "- [ ] **owner** — not looked at", "- [x] **Claude** — ran it")
expect("everything ticked is not reported", 0, len(outstanding([done], "0.8.2")))
found = outstanding([half], "0.8.2")
expect("one unticked box is", 1, len(found))
expect("counted on the right side", (1, 0), (found[0].preview, found[0].rehearsal))

print()
print("a project with no headings at all")
bare = classify(RawIssue(3, "bare", "OPEN", "## Design\n", "Project",
                         {"Phase": "Development", "Route": "x"}, (), 9,
                         "0.8.2", frozenset()))
found = outstanding([bare], "0.8.2")
expect("is reported", 1, len(found))
expect("and told apart from one that said and has not", True,
       found[0].missing_headings)

print()
print("what is deliberately skipped")
# D51: the packages own the test approach, so naming the parent is a finding
# nobody can clear.
parent = wp(4, "- [ ] **owner** — unticked", "- [ ] **Claude** — unticked",
            subs=(RawSubIssue(5, "Project"),))
expect("a parent", 0, len(outstanding([parent], "0.8.2")))
expect("another milestone", 0, len(outstanding([half], "0.9.0")))
decision = classify(RawIssue(6, "d", "OPEN", "", "Decision",
                             {"Decision State": "Asked"}, (), None, None,
                             frozenset()))
# A Decision carries no milestone attribute at all, so the type is tested first.
expect("a decision, without raising", 0, len(outstanding([decision], "0.8.2")))

print()
print("carried over from verify-test-approach.test.sh, which this retires")
# **An unticked post-deployment row is not a test nobody has run.** It is a
# check nobody has answered yet, and counting it here would fail every project
# the moment it shipped. The sections are scoped for exactly this.
mixed = classify(RawIssue(7, "mixed", "OPEN",
    APPROACH % ("- [x] **owner** — looked", "- [x] **Claude** — ran")
    + "\n## Post-deployment checks against requirements\n\n"
      "- [ ] **owner** — did the benefit arrive\n",
    "Project", {"Phase": "Post-deployment", "Route": "x"}, (), 9, "0.8.2",
    frozenset()))
expect("an unticked post-deployment box is not a test", 0,
       len(outstanding([mixed], "0.8.2")))
# The quiet case a broken check passes by accident, so it is here twice.
expect("a milestone with no projects at all", 0, len(outstanding([], "0.8.2")))

print()
print("rendering")
expect("clean says so", True, "nothing outstanding" in render((), "0.8.2", colour=False))
expect("a finding counts both sides", True,
       "1 on Preview, 0 on Rehearsal" in render(outstanding([half], "0.8.2"),
                                                "0.8.2", colour=False))

print()
if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all release cases hold")
PY
