#!/usr/bin/env bash
set -euo pipefail

# board-inbox.test.sh — R2's grouping and event rules, on fixtures.
#
# The fetching is not tested here; it is `gh` and a live board. What is tested
# is the part that used to be spread through `inbox.sh`'s awk and shell: which
# remark belongs to which issue, who is held to have typed it, and what counts
# as opened or closed inside the window.

cd "$(dirname "$0")/.."
python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.inbox import build, render
from board.model import RawIssue
from board.sources import Remark

failures = 0
def check(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

def issue(n, title="t", created=None, closed=None, state="OPEN"):
    return RawIssue(n, title, state, "", "Requirement", {}, (), None, None,
                    frozenset(), frozenset(), frozenset(),
                    created_at=created, closed_at=closed)

SINCE = "2026-09-14T00:00:00Z"

print("grouping")
remarks = (
    Remark(7, "2026-09-15T09:00", "owner", "a question", False),
    Remark(7, "2026-09-15T10:00", "claude", "an answer", False),
    Remark(9, "2026-09-16T09:00", "deploy", "Released in prod-0.8.1", False),
)
inbox = build([issue(7, "seven"), issue(9, "nine")], remarks, SINCE)
check("a thread per issue", 2, len(inbox.threads))
check("remarks stay with their issue", 2, len(inbox.threads[0].remarks))
check("the owner's are counted", 1, inbox.from_owner)

print()
print("a remark on an issue the snapshot does not hold still arrives")
# Something said on an issue outside the window's board is still something said.
inbox = build([], (Remark(404, "2026-09-15T09:00", "owner", "hello", False),), SINCE)
check("the thread exists", 1, len(inbox.threads))
check("with no title rather than being dropped", "", inbox.threads[0].title)

print()
print("opened, closed, and both")
# **Opened *and* closed inside the window needs saying.** Reporting only
# "opened" reads as still-open, which after a week away is the one thing
# somebody would act on wrongly.
issues = [
    issue(1, "opened only", created="2026-09-15T00:00:00Z"),
    issue(2, "closed only", created="2026-09-01T00:00:00Z", closed="2026-09-15T00:00:00Z"),
    issue(3, "both", created="2026-09-15T00:00:00Z", closed="2026-09-16T00:00:00Z"),
    issue(4, "neither", created="2026-09-01T00:00:00Z"),
]
inbox = build(issues, (), SINCE)
check("three events, not four", 3, len(inbox.events))
check("opened", "opened", inbox.events[0].what)
check("closed", "closed", inbox.events[1].what)
check("both is said as both", "opened+closed", inbox.events[2].what)

print()
print("rendering")
out = render(build([issue(7, "seven")],
                   (Remark(7, "2026-09-15T09:00", "owner", "mine", False),),
                   SINCE), colour=False)
check("the owner's remark is marked", True, "> 2026-09-15T09:00  mine" in out)
check("a quiet window says so", True,
      "nothing opened or closed" in render(build([], (), SINCE), colour=False))

print()
if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all inbox cases hold")
PY
