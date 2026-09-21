#!/usr/bin/env bash
set -euo pipefail

# board-milestone.test.sh — does the milestone carry only work that exists?
# Moved from verify.sh's check_milestone, which is retired with this file's
# first half; the second half pins the git side, which is new.
#
# **Two halves because the check has two halves.** What a count *means* is the
# board's question and is tested against fixtures; what counts as a mention is
# git's, and is tested against a real history built in a temporary repository.
# The second was where the risk was: a wrong answer there does not look wrong,
# it looks like an issue nobody has written a commit for.

cd "$(dirname "$0")/.."
HERE="$(pwd)"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue, classify
from board.milestone import carried, render, unbuilt

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

def issue(n, kind="Project", milestone="0.8.2", parent=None, subs=()):
    return classify(RawIssue(n, f"issue {n}", "OPEN", "", kind, {},
                             tuple(subs), parent, milestone, frozenset()))

# A count that only knows about the numbers it was given, so a fixture says
# exactly which issues the history names and nothing is inferred.
def counter(**named):
    return lambda n: named.get(f"n{n}", 0)

print("an issue the history names, and one it does not")
rows = carried([issue(1), issue(2)], "0.8.2", counter(n1=3))
expect("both are reported", [1, 2], [r.number for r in rows])
expect("the named one is built", 3, rows[0].mentions)
expect("and only the other is unbuilt", [2], [r.number for r in unbuilt(rows)])

print()
print("a parent is a fact, never a finding")
# D51: the parent owns the requirements and the design, its packages carry the
# commits. Owner, 2026-09-08: a parent's milestone "should be ignored".
parent = issue(71, subs=(RawSubIssue(268, "Project"),))
rows = carried([parent], "0.8.2", counter())
expect("with no commits of its own, it is still not unbuilt", (), unbuilt(rows))
expect("and it is named as a parent", True, rows[0].a_parent)
# A project with folded requirements under it is NOT a parent -- #214 was
# misread that way once -- so it is asked for commits like any other delivery.
folded = issue(214, subs=(RawSubIssue(9, "Requirement"),))
expect("a project with only folded requirements is a delivery", [214],
       [r.number for r in unbuilt(carried([folded], "0.8.2", counter()))])

print()
print("the rule that took two incidents: the parent's commits are a fact, not credit")
# #373 was split out of #297 the day after 1036e1c said `Refs #297`, and the
# commit being deployed cannot be rewritten. Crediting the parent was tried on
# 2026-09-10 and was wrong: #363 is delivery 2 of #301 and unstarted, and
# #301's delivery-1 commits made it read as merged.
package = issue(363, parent=301)
rows = carried([package, issue(301, subs=(RawSubIssue(363, "Project"),))],
               "0.8.2", counter(n301=7))
by = {r.number: r for r in rows}
expect("the package is still unbuilt", True, by[363].unbuilt)
expect("and the parent's count is carried as the fact", (301, 7),
       (by[363].parent, by[363].parent_mentions))
expect("the reader is told where they are", True,
       "parent #301 has 7" in render(rows, "0.8.2", colour=False))
# The quiet half of the same rule: a package with commits of its own is never
# described by its parent's, because there is nothing to explain.
own = carried([issue(373, parent=297)], "0.8.2", counter(n373=2, n297=40))
expect("a package with its own commits does not mention its parent", None,
       own[0].parent)
# And a parent with nothing either way says only what it can say.
orphan = carried([issue(364, parent=302)], "0.8.2", counter())
expect("no commits anywhere: no parent clause", 0, orphan[0].parent_mentions)
expect("rendered plainly", True,
       "no commit mentions this" in render(orphan, "0.8.2", colour=False)
       and "parent" not in render(orphan, "0.8.2", colour=False))

print()
print("what is in the milestone and what is not")
expect("another milestone is not this one's problem", (),
       carried([issue(5, milestone="1.0.0")], "0.8.2", counter()))
expect("nor is an issue with no milestone at all", (),
       carried([issue(6, milestone=None)], "0.8.2", counter()))
# Every type, not only deliveries: #380 and #379 were requirements sitting in
# 0.8.1, which is the shape this catches.
mixed = carried([issue(7, kind="Requirement"), issue(8, kind="Decision")],
                "0.8.2", counter())
expect("a requirement in a release milestone is checked", [7, 8],
       [r.number for r in mixed])
# **Pull requests are not issues.** `gh issue list --milestone` never returned
# one, and a PR carrying the milestone ships nothing of its own.
pr = classify(RawIssue(9, "a pull request", "OPEN", "", "PullRequest", {},
                       (), None, "0.8.2", frozenset()))
expect("a pull request on the milestone is not a finding", (),
       carried([pr], "0.8.2", counter()))
# An untyped issue is classified as a Requirement so some rule owns it (#361),
# and is still reported as untyped, because the type is the thing to fix.
untyped = carried([issue(10, kind=None)], "0.8.2", counter(n10=1))
expect("an untyped issue says so", "untyped", untyped[0].kind)

print()
print("rendering")
expect("an empty milestone says so plainly", True,
       "has no open issues" in render((), "0.8.2", colour=False))
built = render(carried([issue(1)], "0.8.2", counter(n1=4)), "0.8.2", colour=False)
expect("a built issue shows its count", True, "4 commits" in built)
expect("and is not listed as unbuilt", False, "unbuilt:" in built)
missing = render(carried([issue(1), issue(2)], "0.8.2", counter(n1=4)),
                 "0.8.2", colour=False)
expect("the unbuilt are listed together, as verify.sh did", True,
       "unbuilt: #2" in missing)

print()
if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all milestone cases hold")
PY

echo
echo "what counts as a mention, against a real history"

# Carried over from issue-mentions.test.sh, which keeps testing the bash copy
# `deploy.sh` still sources. Both must answer the same, and on 2026-09-21 they
# did not: the model matched case-insensitively and skipped merge commits, so
# two prose sentences counted as trailers and #362's only trailer -- on a merge
# into a release branch -- counted for nothing.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(
  cd "$work"
  git init -q -b main .
  git config user.email t@example.com
  git config user.name test
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: one

Refs #17"
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: two

Refs #170"
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: three

Closes #17"
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: prose only

This mentions #17 and says it now refs #17 in a sentence, which is not a
trailer. It also says that closes #17, still in prose.

Refs #99"
  git checkout -q -b merged
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: on a branch that lands

Refs #501"
  git checkout -q main
  git merge -q --no-ff merged -m "app 0.0.1 api 1.0: merge the branch

Refs #362"
  git checkout -q -b unmerged
  git commit -q --allow-empty -m "app 0.0.1 api 1.0: work in progress

Refs #500"
  git checkout -q main
)

python3 - "$work" "$HERE" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[2])
os.chdir(sys.argv[1])
from board.repo import mentions_on

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: wanted {want!r}, got {got!r}")
        failures += 1

scope = mentions_on("HEAD")
# Two trailers name #17 and two prose sentences do. Only the trailers count:
# matching any `#N` refused the 0.7.2 release, when b231721 named #224 and #241
# as examples in its prose and the gate read that as both of them shipping.
expect("the trailer counts, the prose does not", 2, scope.count(17))
expect("#17 is not #170-something", 1, scope.count(170))
expect("a commit that closes is not also referencing", 1,
       len(scope.closes.get(17, [])))
expect("a trailer in a body with prose still counts", 1, scope.count(99))
# The gate counts merges, so the pre-flight must: a pre-flight that passes
# where the deploy refuses stops the release at the point stopping costs most.
expect("a merge commit's trailer counts", 1, scope.count(362))
# A commit that never reached this ref is not built, however it is named.
expect("a merged branch's own commit counts too", 1, scope.count(501))
expect("a branch not merged here is not counted", 0, scope.count(500))

if failures:
    print(f"{failures} failure(s)"); sys.exit(1)
print("all mention cases hold")
PY

echo
echo "and the same answers as the gate's own copy"

# **The two implementations are compared, not read.** `deploy.sh` refuses on
# `issue-mentions.sh`; this pre-flight reports on `repo.mentions_on`, and the
# failure nobody would see is the pre-flight passing where the gate refuses.
# Asserting the counts match on one history is the only form of that check
# which survives either side being edited.
source "$HERE/issue-mentions.sh"
model="$(python3 -c "
import os, sys
sys.path.insert(0, sys.argv[2]); os.chdir(sys.argv[1])
from board.repo import mentions_on
scope = mentions_on('HEAD')
print(' '.join(str(scope.count(n)) for n in (17, 99, 170, 362, 500, 501)))
" "$work" "$HERE")"
bash_counts=""
for n in 17 99 170 362 500 501; do
  bash_counts+="$(cd "$work" && commits_mentioning HEAD "$n") "
done
if [[ "$model" == "${bash_counts% }" ]]; then
  printf '  ok   both copies count the same history the same way (%s)\n' "$model"
else
  printf '  FAIL the two copies disagree\n       model: %s\n       bash:  %s\n' \
    "$model" "${bash_counts% }"
  exit 1
fi
