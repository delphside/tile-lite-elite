#!/usr/bin/env bash
set -euo pipefail

# digest.test.sh — D54's weekly digest, #382.
#
# The digest exists to hold me to a limit, so the cases that matter are the
# ones where a bug would flatter the report:
#
#   direction     a share that is not falling must say so, not round kindly
#   threshold     45% and the 2026-10-17 horizon stand as PROPOSED — the owner
#                 was asked to confirm them and has not, and an unconfirmed
#                 number must not harden into a fact by being repeated
#   judgement     "anything I decided that you might have decided differently"
#                 cannot be derived; an empty section must say it was not
#                 written, never that there was nothing
#
# No network and no git: canned counts only.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

python3 - <<'PY'
import collections
import sys
sys.path.insert(0, ".")
from board.digest import Digest, render, THRESHOLD, MEASURED_AT

failures = 0

def check(what, want, got):
    global failures
    if got == want:
        print(f"  ok   {what}")
    else:
        print(f"  FAIL {what}\n       want {want!r}\n       got  {got!r}")
        failures += 1

def digest(tooling, total, **kw):
    d = Digest(since="2026-09-17", until="HEAD", tooling=tooling, total=total, **kw)
    d.by_type = collections.Counter({"tooling": tooling, "other": total - tooling})
    return d

print("the share is arithmetic, and the direction is honest about it")
check("below the threshold", True, "below" in digest(4, 10).direction)
check("falling but not there yet", True, "falling" in digest(48, 100).direction)
# 55% is where D54 measured it. Anything at or above that is not falling, and
# the digest must not describe it as progress.
check("not falling is said plainly", True, "not falling" in digest(55, 100).direction)
check("worse than when it started is also not falling",
      True, "not falling" in digest(70, 100).direction)
check("the share rounds down, never up", 48, digest(48, 100).share)
check("no issues at all does not divide by zero", 0, digest(0, 0).share)

print()
print("an unconfirmed threshold is repeated as unconfirmed")
text = render(digest(48, 100))
check("the threshold appears", True, f"{THRESHOLD}%" in text)
check("and is marked as standing only as proposed",
      True, "stand as proposed" in text)
check("the measured starting point is not lost", True, str(MEASURED_AT) in text)

print()
print("what cannot be derived is not reported as nothing")
check("an unwritten judgement section says so",
      True, "was not written" in render(digest(48, 100)))
check("and does not claim there was nothing",
      False, "nothing to report" in render(digest(48, 100)))
written = render(digest(48, 100), ["I left status.sh alone"])
check("a supplied judgement is shown", True, "I left status.sh alone" in written)
check("and the disclaimer goes away", False, "was not written" in written)

print()
print("deletion is reported even when it is zero, because that is the point")
# D54: "removing tooling is as much in scope as adding it, and needs no more
# permission" — so a week that added 4000 lines and removed none must say it.
plain = render(digest(48, 100, lines_added=4174, lines_removed=334))
check("nothing removed is stated, not omitted",
      True, "Nothing was removed this week." in plain)
check("the line counts appear", True, "4174 lines added, 334 removed" in plain)
some = render(digest(48, 100, files_deleted=["scripts/old.sh"]))
check("a deleted file is named", True, "`scripts/old.sh`" in some)

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all digest cases hold")
PY
