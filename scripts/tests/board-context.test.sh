#!/usr/bin/env bash
set -euo pipefail

# board-context.test.sh — R10's header and R11's dependency check, #383.
#
# No network: canned issues only.
#
#   identical         every member of a family carries the same header
#   parent            a parent's route and milestone are not shown
#   dependencies      named with titles; links inside the family left out
#   rewrite           writing a header twice changes nothing, and the rest of
#                     the body survives
#   R11               only the Dependencies section is read — #71's table of
#                     placements said "waits on #253" about #251

cd "$(dirname "$0")/.."

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue, classify
from datetime import date
from board.context import (INTRODUCTION, current, declared, fields_visible,
                           headers, missing_members, needs_writing,
                           short_title, stale, undeclared_links, with_header)

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       want {want!r}\n       got  {got!r}")
        failures += 1

def raw(n, title, kind="Project", fields=None, subs=(), parent=None,
        milestone=None, body="", blocked_by=(), blocks=(), state="OPEN"):
    return RawIssue(n, title, state, body, kind, fields or {}, tuple(subs),
                    parent, milestone, frozenset(),
                    blocked_by=frozenset(blocked_by), blocks=frozenset(blocks))

def board_of(*raws):
    return {r.number: classify(r) for r in raws}

print("short titles")
expect("parent prefix dropped", "TLE Scheduler",
       short_title("#400 MAIN PROJECT: TLE Scheduler"))
expect("package letter kept, counts dropped", "WP A: Scheduler core",
       short_title("#400 WP A Del 1 of 1, pt 1 of 2: Scheduler core"))
expect("outside its family a package keeps its parent", "Additional Game Lifecycle (#71 WP C)",
       short_title("#71 WP C: Additional Game Lifecycle", outside=True))
expect("an unprefixed title is left alone", "Idle game removal",
       short_title("Idle game removal"))

board = board_of(
    raw(400, "#400 MAIN PROJECT: TLE Scheduler",
        fields={"Phase": "Scope", "Route": "Production Release"},
        milestone="0.8.2",
        subs=[RawSubIssue(414, "Project"), RawSubIssue(415, "Project")],
        blocks=(224,)),
    raw(414, "#400 WP A Del 1 of 1, pt 1 of 2: Scheduler core", parent=400,
        fields={"Phase": "User testing", "Route": "Production Release"},
        milestone="0.8.2", blocks=(415,)),
    raw(415, "#400 WP B Del 1 of 1, pt 2 of 2: Admin CLI and tests", parent=400,
        fields={"Phase": "Scope"}, milestone="0.8.2",
        blocked_by=(414, 256)),
    raw(411, "#414 Scheduler core", kind="PullRequest", body="Refs #414"),
    raw(224, "Monitoring and alarming gaps", blocked_by=(400,)),
)
titles = {n: i.title for n, i in board.items()}
titles[256] = "Split sweeps along purpose"
TODAY = date(2026, 9, 24)
h = headers(board, titles, TODAY)

print("R10: one header per family")
expect("parent and both packages carry the same header", 1,
       len({h[400], h[414], h[415]}))
expect("a parent's route and milestone are not shown", True,
       "| #400 TLE Scheduler | Scope | — | — | — |" in h[400])
expect("a package shows its own, and its open pull request", True,
       "| #414 WP A: Scheduler core | User testing | Production Release | 0.8.2 | #411 |" in h[400])
expect("waits on is named, and #414 -> #415 inside the family is left out", True,
       "Waits on: #256 Split sweeps along purpose" in h[400])
expect("needed by is named", True,
       "Needed by: #224 Monitoring and alarming gaps" in h[400])

expect("it opens with the day it was written",
       "## Context as of Thursday 24 September 2026", h[400].split("\n")[1])

print("R10: writing it")
body = "## Requirements\n\nR1\n"
once = with_header(body, h[400])
twice = with_header(once, h[400])
expect("writing twice changes nothing", once, twice)
expect("the rest of the body survives", True, once.endswith(body))
prose = with_header("Raised 2026-09-22.\n\n## Requirements\n", h[400])
expect("prose under the header is titled", True,
       f"<!-- /context -->\n\n{INTRODUCTION}\n\nRaised 2026-09-22." in prose)
expect("and titled once, however often it is written", prose,
       with_header(prose, h[400]))
expect("a body opening with a heading gets no introduction", False,
       INTRODUCTION in once)
fresh = board_of(raw(400, "#400 MAIN PROJECT: TLE Scheduler", body=once,
                     fields={"Phase": "Scope"},
                     subs=[RawSubIssue(414, "Project"), RawSubIssue(415, "Project")],
                     blocks=(224,)))[400]
expect("the header read back is the one written", h[400], current(fresh))
expect("a body without one is reported", True,
       (224, "no header") in stale(board, titles))
tomorrow = headers(board, titles, date(2026, 9, 25))[400]
expect("the next day, unchanged facts need no write", False,
       needs_writing(fresh, tomorrow))
expect("nor does board-check call it stale", [], [f for f in stale(
    {**board, 400: fresh}, titles) if f[0] == 400])
moved = board_of(raw(400, "#400 MAIN PROJECT: TLE Scheduler", body=once,
                     fields={"Phase": "Design and Test Approach"},
                     subs=[RawSubIssue(414, "Project"), RawSubIssue(415, "Project")],
                     blocks=(224,)))
moved = {**board, **moved}
expect("a phase that moved does need one", True,
       needs_writing(moved[400], headers(moved, titles, TODAY)[400]))

print("R10: a closed package is still part of the family")
fam = board_of(
    raw(329, "#329 MAIN PROJECT: document and generalise errors",
        fields={"Phase": "Design and Test Approach"},
        subs=[RawSubIssue(398, "Project"), RawSubIssue(399, "Project")]),
    raw(399, "#329 WP B Del 2 of 2: Generalise API database errors", parent=329,
        fields={"Phase": "Deployment"}, milestone="0.8.2"),
)
expect("the open board lacks it, so it is asked for", [398], missing_members(fam))
fam.update(board_of(raw(398, "#329 WP A Del 1 of 2: the errors documented", parent=329,
                        fields={"Phase": "Project Closedown"}, milestone="pre-approved",
                        state="CLOSED")))
ht = headers(fam, {n: i.title for n, i in fam.items()}, TODAY)
expect("it is listed, and says it is closed", True,
       "| #398 WP A: the errors documented | Project Closedown, closed |" in ht[329])
expect("the closed package is given no header of its own", False, 398 in ht)
expect("and nothing more is missing", [], missing_members(fam))

print("R10: a token that cannot see fields")
blind = board_of(raw(1, "a"), raw(2, "b"))
expect("no project with a Phase means the fields are not visible", False,
       fields_visible(blind))
expect("one with a Phase is enough", True, fields_visible(board))

print("R11: declared in the Dependencies section")
expect("several numbers after one phrase, with an R suffix", [
    ("is needed by", 224), ("is needed by", 270)],
    declared("**is needed by #224 R4, #270** — reasons"))

deps = """## Requirements

| #251 | waits on #253: placed by dependency |

## Dependencies and related work

**waits on #400** — the scheduler.

**is needed by #405**.

## Deliveries
"""
b = board_of(raw(71, "#71 MAIN PROJECT: One Game Model", body=deps,
                 blocked_by=(400,)))
found = [(f.number, f.phrase, f.other) for f in undeclared_links(b)]
expect("a table row elsewhere in the body is not read", True,
       all(o != 253 for _, _, o in found))
expect("a link GitHub holds is not reported", True,
       all(o != 400 for _, _, o in found))
expect("a declaration GitHub does not hold is", [(71, "is needed by", 405)], found)

if failures:
    print(f"{failures} failed")
    sys.exit(1)
print("all passed")
PY
