#!/usr/bin/env bash
set -euo pipefail

# roadmap.test.sh — the dateless Gantt, R8.
#
# The picture is only as good as what it chooses to draw, so what is tested is
# the choosing: which issues get a bar, what a dependency on a parent means,
# and where a bar sits when nothing sequences it. No network: canned issues.
#
#   bars          deliveries only — a parent makes none, so it has none
#   lifting       blocked by a parent means blocked by every delivery it makes
#   columns       longest path, and 0 when nothing blocks it
#   cycles        reported, not recursed into

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue
from board.roadmap import build, draw
from board.sources import Snapshot

failures = 0

def check(what, want, got):
    global failures
    if got == want:
        print(f"  ok   {what}")
    else:
        print(f"  FAIL {what}\n       want {want!r}\n       got  {got!r}")
        failures += 1

def issue(number, kind="Project", subs=(), parent=None, ws="W",
          milestone=None, blocked_by=()):
    return RawIssue(number, f"issue {number}", "OPEN", "", kind,
                    {"Workstream": ws, "Phase": "Q1"}, tuple(subs), parent,
                    milestone, frozenset(), frozenset(blocked_by), frozenset())

def road(*raws, **kw):
    return build(Snapshot(tuple(raws), 0.0, 0.0, 1, False), **kw)

def drawn(r):
    return sorted(i.number for lane in r.lanes.values() for i in lane)

print("a bar is a delivery: a parent makes none, so it has none")
r = road(
    issue(71, subs=[RawSubIssue(268, "Project"), RawSubIssue(269, "Project")]),
    issue(268, parent=71), issue(269, parent=71),
    issue(9),                                   # standalone: carries a milestone
    issue(5, kind="Requirement"), issue(6, kind="Decision"),
    issue(7, kind="PullRequest"),
)
check("parent has no bar, its packages and a standalone do", [9, 268, 269], drawn(r))

print()
print("blocked by a parent means blocked by every delivery it makes")
r = road(
    issue(71, subs=[RawSubIssue(268, "Project"), RawSubIssue(269, "Project")]),
    issue(268, parent=71), issue(269, parent=71),
    issue(10, blocked_by=[71]),
)
check("one recorded dependency becomes two arrows",
      [(268, 10), (269, 10)], r.edges)
check("and is reported as lifted, not silently multiplied",
      [(71, 10)], sorted({(b, i) for b, i, _ in r.lifted}))
check("the blocked bar sits one column right", 1, r.rank[10])
check("its blockers start at the left", [0, 0], [r.rank[268], r.rank[269]])

print()
print("a parent's own blocker reaches its packages too")
r = road(
    issue(71, subs=[RawSubIssue(268, "Project")], blocked_by=[9]),
    issue(268, parent=71), issue(9),
)
check("blocking a parent blocks its deliveries", [(9, 268)], r.edges)

print()
print("columns are the longest path, so a chain spreads out")
r = road(issue(1), issue(2, blocked_by=[1]), issue(3, blocked_by=[1, 2]))
check("a three-link chain occupies three columns",
      [0, 1, 2], [r.rank[1], r.rank[2], r.rank[3]])
check("nothing recorded means column 0", 1, r.unsequenced)

print()
print("unsequenced is the normal case and is counted, not hidden")
r = road(issue(1), issue(2), issue(3))
check("three bars, none sequenced", 3, r.unsequenced)
check("and no arrows invented", [], r.edges)

print()
print("a cycle is reported rather than recursed into")
r = road(issue(1, blocked_by=[2]), issue(2, blocked_by=[1]))
check("both still get a column", 2, len(r.rank))
check("and the cycle is named", True, bool(r.cycles))

print()
print("swimlanes are workstreams, and unset is its own lane")
r = road(issue(1, ws="Client UI"), issue(2, ws="Game Rules"),
         issue(3, ws=None))
check("one lane per workstream, unset last",
      ["Client UI", "Game Rules", "no workstream set"], list(r.lanes))

print()
print("the drawing says what it drew")
r = road(issue(1, ws="Client UI", milestone="0.8.1"), issue(2, blocked_by=[1]))
text = draw(r)
check("a bar carries its milestone", True, "0.8.1" in text)
check("a missing milestone is visible, not blank", True, "milestone not set" in text)
check("swimlanes are subgraphs", True, 'subgraph lane0["Client UI"]' in text)
check("left to right", True, "flowchart LR" in text)
check("no dates anywhere", True, "dateFormat" not in text and "gantt" not in text)

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all roadmap cases hold")
PY
