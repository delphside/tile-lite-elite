#!/usr/bin/env bash
set -euo pipefail

# programme.test.sh — R3's derived facts, #383.
#
# The state of a change is derived from commits so that nothing has to be kept
# up to date. That makes the derivation the only thing worth testing, and each
# case here is one that has been wrong in a real report.
#
#   precedence    asking "is it released" before "is work happening" made an
#                 issue with old shipped commits and a live branch read as
#                 released — the one state that stops anybody looking again
#   the route     a Repository Change is live at merge, so "awaiting release"
#                 is wrong for it. Nine closed changes once piled up there
#   the parent    a package built before it existed carries its parent's
#                 number (#373, #375). Do NOT count those as the package's
#
# No network and no git: canned commits only.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board import repo
from board.model import RawIssue, RawSubIssue
from board.programme import changes
from board.sources import Snapshot

failures = 0

def check(what, want, got):
    global failures
    if got == want:
        print(f"  ok   {what}")
    else:
        print(f"  FAIL {what}\n       want {want!r}\n       got  {got!r}")
        failures += 1

def scope(closes=(), refs=()):
    s = repo.Scope()
    s.closes = {n: ["deadbee"] for n in closes}
    s.refs = {n: ["deadbee"] for n in refs}
    return s

def commits(**kw):
    return repo.Commits(last_tag="prod-0.8.0", **kw)

print("`Refs #N` means work touched it; `Closes #N` means it is done")
# Owner, 2026-09-18. Commits say `Refs #N` and the DEPLOY closes them;
# `Closes #N` is correct only where the change never leaves the repository.
# Reading the two as the same made an incidental mention of #10 in an old
# commit report the Bot client harness as released while it sat at Scope.
c = commits(released=scope(refs=[10]))
check("an old mention is not a delivery",
      "mentioned before prod-0.8.0", c.state_of(10, False))
c = commits(released=scope(closes=[10]))
check("a closing commit in production is", "released", c.state_of(10, False))
c = commits(unreleased=scope(closes=[10]))
check("a closing commit on main, not yet released",
      "closed by a commit on main", c.state_of(10, False))
# A commit that closes an issue is not also merely referencing it.
one = repo.Scope(); one.closes = {5: ["a"]}
check("a closing commit is not counted twice", 1, one.count(5))

print()
print("the milestone is the delivery evidence, with or without commits")
# docs/3.3: `Closes #N` fires when a commit reaches the default branch —
# written, not shipped. So the deploy closes an issue and the milestone means
# "in production". #362 and #373 were split out of their parents after the
# work landed, so they carry no commits of their own and still shipped.
c = commits()
check("a shipped milestone and no commits at all is still released",
      "released in 0.8.0", c.state_of(362, False, "0.8.0", frozenset({"0.8.0"})))
check("an unshipped milestone is not", "not started",
      c.state_of(362, False, "1.0.0", frozenset({"0.8.0"})))
check("pre-approved never ships via a release", "not started",
      c.state_of(362, True, "pre-approved", frozenset({"0.8.0"})))
c = commits(released=scope(refs=[295]))
check("a mention plus a shipped milestone is released",
      "released in 0.8.0", c.state_of(295, False, "0.8.0", frozenset({"0.8.0"})))
check("the same mention without one is not",
      "mentioned before prod-0.8.0", c.state_of(295, False, None, frozenset()))
# Work in progress still wins: an issue reopened after a release is not done.
c = commits(off_main=scope(refs=[1]))
check("work on a branch beats a shipped milestone", "in progress",
      c.state_of(1, False, "0.8.0", frozenset({"0.8.0"})))

print()
print("state precedence is newest work first")
c = commits(off_main=scope(refs=[1]), unreleased=scope(refs=[1]),
            released=scope(closes=[1]))
check("work in progress beats everything", "in progress", c.state_of(1, False))
c = commits(unreleased=scope(refs=[1]), released=scope(closes=[1]))
check("an unreleased commit beats an old released one",
      "merged, awaiting release", c.state_of(1, False))
check("and nothing at all means not started", "not started",
      commits().state_of(1, False))

print()
print("the route decides whether it waits for a release")
c = commits(unreleased=scope(refs=[1]))
check("a production release waits", "merged, awaiting release", c.state_of(1, False))
check("a repository change does not", "merged", c.state_of(1, True))

print()
print("a package built under its parent's number is not claimed as built")
def issue(number, kind="Project", parent=None, fields=None, milestone=None):
    return RawIssue(number, f"issue {number}", "OPEN", "", kind,
                    fields or {"Route": "Production Release", "Phase": "Post-deployment"},
                    (), parent, milestone, frozenset())

snap = Snapshot((issue(373, parent=297),), 0.0, 0.0, 1, False)
c = commits(released=scope(refs=[297]))
got = changes(snap, c)[0]
check("the package still reads as not started", "not started", got.state)
check("and says where the commits are instead",
      True, "#297 carries 1" in got.note)
# Counting the parent's commits as the package's would make every package of
# a parent look built, which is the failure the rule exists to prevent.
check("it does not claim the parent's commits", False, "released" == got.state)

snap = Snapshot((issue(374, parent=297),), 0.0, 0.0, 1, False)
got = changes(snap, commits(unreleased=scope(refs=[374]),
                            released=scope(refs=[297])))[0]
check("a package with its own commits needs no note", "", got.note)

print()
print("the commits and the board can disagree, and that is reported")
snap = Snapshot((issue(10, fields={"Route": "Repository Change", "Phase": "Scope"}),),
                0.0, 0.0, 1, False)
got = changes(snap, commits(released=scope(closes=[10])))[0]
check("shipped, but the board says Scope", True, got.disagrees)
# An old `Refs` is a mention the convention explicitly allows. Treating it as
# a contradiction reported four changes as disagreeing with the board when the
# derivation was what was wrong.
check("an old mention is not a contradiction", False,
      changes(snap, commits(released=scope(refs=[10])))[0].disagrees)
snap = Snapshot((issue(11, fields={"Route": "Repository Change",
                                   "Phase": "Post-deployment"}),), 0.0, 0.0, 1, False)
check("shipped and the board agrees", False,
      changes(snap, commits(released=scope(closes=[11])))[0].disagrees)

print()
print("only deliveries get a row")
snap = Snapshot((issue(1, kind="Requirement"), issue(2, kind="Decision"),
                 RawIssue(3, "parent", "OPEN", "", "Project", {},
                          (RawSubIssue(4, "Project"),), None, None, frozenset()),
                 issue(4, parent=3)), 0.0, 0.0, 1, False)
check("a requirement, a decision and a parent are not deliveries",
      [4], [c.number for c in changes(snap, commits())])

print()
print("an environment that did not answer is not an empty one")
check("an unparsable version yields no comparison", "", repo.behind_main(None))
check("a version with no build sha yields none either", "", repo.behind_main("0.8.0"))

print()
print("R7 reduces two vocabularies to one word each")
from board.diff import ROW, _bucket
check("status.sh's tooling wording", "merged",
      _bucket("merged — smoke-test, then close · pre-approved"))
check("its documentation wording", "merged", _bucket("merged — close it · pre-approved"))
check("its release wording", "merged", _bucket("merged, awaiting release · 1.0.0"))
check("a branch it names", "in progress", _bucket("in progress (290-dioxus-07)"))
check("no trailer, but merged", "merged", _bucket("merged (no Refs trailer)"))
check("the model's own", "mentioned only", _bucket("mentioned before prod-0.8.0"))
check("and its released form", "released", _bucket("released in 0.8.0"))
row = ROW.match("    10   Bot client harness: run an en\u2026 tooling          merged — smoke-test, then close")
check("a status.sh row parses", ("10", "tooling"),
      (row.group(1), row.group(2)) if row else None)

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all programme cases hold")
PY
