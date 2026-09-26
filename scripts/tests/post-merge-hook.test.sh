#!/usr/bin/env bash
set -euo pipefail

# post-merge-hook.test.sh — a merged project branch moves its work package on.
#
# Two halves. The hook's half is git's: it must fire for `git merge <N-branch>`
# on main and for nothing else, since the same hook runs on every pull. That is
# tested in a scratch repository, with the board call replaced by a stub. The
# decision's half is the board's: which issue a merge delivered, and where its
# Phase goes. That is tested on canned issues, with no network.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HERE/../.githooks/post-merge"
failures=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/stub.sh"
CALLS="$WORK/calls"
printf '#!/usr/bin/env bash\necho "$1" >> "%s"\n' "$CALLS" > "$STUB"
chmod +x "$STUB"

repo() {  # a repository with main, a numbered branch one commit ahead, and the hook
  local dir="$WORK/$1"
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit -q --allow-empty -m base
  git -C "$dir" checkout -q -b "$2"
  git -C "$dir" commit -q --allow-empty -m work
  git -C "$dir" checkout -q main
  cp "$HOOK" "$dir/.git/hooks/post-merge"
  printf '%s' "$dir"
}

called() { [ -f "$CALLS" ] && cat "$CALLS" || true; }

echo "the hook"
rm -f "$CALLS"; d="$(repo a 415-x)"
POST_MERGE_CMD="$STUB" git -C "$d" merge -q --ff-only 415-x
[ "$(called)" = "415-x" ] && ok "a numbered branch fast-forwarded into main runs it" \
  || fail "a numbered branch fast-forwarded into main runs it: got '$(called)'"

rm -f "$CALLS"; d="$(repo b 415-x)"
git -C "$d" update-ref refs/remotes/origin/415-x 415-x
POST_MERGE_CMD="$STUB" git -C "$d" merge -q --ff-only origin/415-x
[ "$(called)" = "415-x" ] && ok "so does its remote-tracking ref, named without origin/" \
  || fail "so does its remote-tracking ref: got '$(called)'"

rm -f "$CALLS"; d="$(repo c tidy-up)"
POST_MERGE_CMD="$STUB" git -C "$d" merge -q --ff-only tidy-up
[ -z "$(called)" ] && ok "a branch with no issue number does not" || fail "an unnumbered branch ran it"

rm -f "$CALLS"; d="$(repo d 415-x)"
git -C "$d" checkout -q -b 416-y main
POST_MERGE_CMD="$STUB" git -C "$d" merge -q --ff-only 415-x
[ -z "$(called)" ] && ok "a merge on a project branch does not" || fail "a merge off main ran it"

rm -f "$CALLS"; d="$(repo e 415-x)"
git clone -q "$d" "$WORK/clone"
git -C "$d" checkout -q main && git -C "$d" merge -q --ff-only 415-x 2>/dev/null || true
rm -f "$CALLS"
cp "$HOOK" "$WORK/clone/.git/hooks/post-merge"
POST_MERGE_CMD="$STUB" git -C "$WORK/clone" pull -q --ff-only 2>/dev/null
[ -z "$(called)" ] && ok "a pull into main does not, though it is a merge too" || fail "a pull ran it: got '$(called)'"

rm -f "$CALLS"; d="$(repo f 415-x)"
POST_MERGE_CMD="/bin/false" git -C "$d" merge -q --ff-only 415-x && ok "a failing board call does not fail the merge" \
  || fail "a failing board call failed the merge"

echo "the decision"
cd "$HERE"
python3 - <<'PY' || failures=$((failures + 1))
import sys
sys.path.insert(0, ".")
from board.model import RawIssue, RawSubIssue, classify
from board.merge import moves, named, next_phase

bad = 0
def expect(name, want, got):
    global bad
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       want {want!r}\n       got  {got!r}")
        bad += 1

def issue(n, phase=None, route=None, parent=None, subs=(), kind="Project", state="OPEN"):
    fields = {k: v for k, v in (("Phase", phase), ("Route", route)) if v}
    return classify(RawIssue(n, f"#{n}", state, "", kind, fields, tuple(subs),
                             parent, None, frozenset()))

expect("the pull request names the package the branch does not",
       [400, 414], named("400-scheduler-mechanism", "#414 Scheduler core", "Refs #414, `#400 WP A`."))
expect("a branch with no pull request still names itself", [415], named("415-x"))

wp = lambda phase, route="Production Release", **k: issue(414, phase, route, parent=400, **k)
expect("an image change in user testing goes to Deployment", "Deployment", next_phase(wp("User testing")))
expect("so does one merged straight from Development", "Deployment", next_phase(wp("Development")))
expect("a repository change's merge is its delivery", "Post-deployment",
       next_phase(wp("User testing", "Repository Change")))
expect("a Phase already past the merge is left alone", None, next_phase(wp("Deployment")))
expect("nothing moves backwards", None, next_phase(wp("Post-deployment")))
expect("an Other route has no merge to complete", None, next_phase(wp("User testing", "Other")))
expect("a closed package is left alone", None, next_phase(wp("User testing", state="CLOSED")))
parent = issue(400, "Scope", subs=[RawSubIssue(414, "Project"), RawSubIssue(415, "Project")])
expect("a parent does not deliver", None, next_phase(parent))
expect("a requirement has no Phase to move", None,
       next_phase(issue(418, "User testing", "Repository Change", kind="Requirement")))
expect("the #414 case: the parent named by the branch is skipped, the package moved",
       [(414, "User testing", "Deployment")],
       moves([400, 414], {400: parent, 414: wp("User testing")}))
sys.exit(1 if bad else 0)
PY

echo
if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
