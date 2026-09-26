#!/usr/bin/env bash
set -euo pipefail

# board-refs.test.sh — which issue a commit, a pull request or a branch names.
#
# The rule has one owner, `scripts/board/refs.py`; until 2026-09-26 it had six
# copies that disagreed (#421). The cases are the rule's own, from
# `issue-mentions.sh`'s measured decision: the capitalised trailer counts, and
# prose does not. The second half runs `board-refs.py` against a real history,
# because that command is what the hooks and deploy.sh ask.

cd "$(dirname "$0")/.."
HERE="$(pwd)"

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board import refs

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       want {want!r}\n       got  {got!r}")
        failures += 1

print("a message")
expect("Refs and Closes both name", {12, 34}, refs.named("fix it\n\nRefs #12\nCloses #34"))
expect("only Closes closes", {34}, refs.closes("Refs #12\nCloses #34"))
expect("prose in lower case is not a trailer", set(), refs.named("this closes #103 eventually, refs #9"))
expect("GitHub's other keywords are not ours", set(), refs.named("Fixes #5\nResolves #6"))
expect("a colon is not our form", set(), refs.named("Refs: #7"))
expect("a longer number is not a shorter one", {1234}, refs.named("Refs #1234"))

print("a pull request")
expect("the title's leading number", {414}, refs.pull_request_names("#414 Scheduler core", ""))
expect("and the body's trailers", {414, 400}, refs.pull_request_names("#414 Scheduler core", "Refs #400."))
expect("a number later in the title is not the lead", set(), refs.pull_request_names("fix for #12", ""))

print("a branch")
expect("N-name", 415, refs.branch_issue("415-admin-cli"))
expect("the older issue-N-name", 214, refs.branch_issue("issue-214-build-once"))
expect("a remote-tracking name", 415, refs.branch_issue("origin/415-admin-cli"))
expect("an unnumbered branch", None, refs.branch_issue("tidy-up"))
expect("main", None, refs.branch_issue("main"))

sys.exit(1 if failures else 0)
PY

echo "the command, against a real history"
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
git init -q -b main "$REPO"
c() { git -C "$REPO" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "$1"; }
c "base"
c $'one\n\nRefs #7'
c $'two, which closes #7 in passing\n\nCloses #8'
git -C "$REPO" tag mid
c $'three\n\nRefs #7\nRefs #9'
git -C "$REPO" checkout -q -b side mid
c $'side work'
git -C "$REPO" checkout -q main
git -C "$REPO" -c user.email=t@e -c user.name=t merge -q --no-ff side -m $'merge side\n\nRefs #11'

failures=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi; }
R="$HERE/board-refs.py"
check "count: commits naming #7, prose in #8's commit not counted" 2 "$(python3 "$R" -C "$REPO" count main 7)"
check "count: a merge's trailer counts" 1 "$(python3 "$R" -C "$REPO" count main 11)"
check "count over a range" 1 "$(python3 "$R" -C "$REPO" count mid..main 7)"
check "numbers: every issue named, ascending" "7 8 9 11" "$(python3 "$R" -C "$REPO" numbers main | tr '\n' ' ' | sed 's/ $//')"
check "commits: the right ones" 2 "$(python3 "$R" -C "$REPO" commits main 7 | wc -l | tr -d ' ')"
check "an unknown revision names nothing, and exits 0" 0 "$(python3 "$R" -C "$REPO" count no-such-ref 7)"
check "named, from a message on stdin" "3 4" "$(printf 'x\n\nRefs #4\nCloses #3\nfixes #5\n' | python3 "$R" named | tr '\n' ' ' | sed 's/ $//')"
check "branch" 415 "$(python3 "$R" branch 415-x)"
check "an unnumbered branch prints nothing" "" "$(python3 "$R" branch tidy-up)"
set +e; python3 "$R" frobnicate >/dev/null 2>&1; rc=$?; set -e
check "an unknown command is refused" 2 "$rc"

if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
