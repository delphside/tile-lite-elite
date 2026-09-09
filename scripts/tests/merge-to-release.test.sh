#!/usr/bin/env bash
set -euo pipefail

# Tests merge-to-release.sh (#344 R4, R5) under the same `set -euo pipefail` it
# runs with — a harness missing `pipefail` once hid a bug that reached a
# production deploy.
#
# `gh` and `ci-status.sh` are both stubbed, because the whole point of the
# script is which questions it asks and what it does with the answers. The
# merge itself is GitHub's and is not under test; that it is *not reached* when
# a check fails is the thing that matters, and is asserted below.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/merge-to-release.sh"
failures=0

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

# One stub for every `gh` call the script makes, dispatching on the subcommand.
# `MERGED` records that the merge was reached, which is how "it refused" is told
# apart from "it passed and did nothing".
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")   cat "$STUB_DIR/pr.json" ;;
  # Records the whole call, not just that it happened. The strategy is the
  # thing that matters and was unasserted until 2026-09-09: `--rebase` rewrites
  # the commits, so the tested SHA is not the landed SHA and the commit stamp
  # breaks after the merge, where nothing can see it.
  "pr merge")  printf '%s\n' "$*" > "$STUB_DIR/MERGED" ;;
  "api "*)     cat "$STUB_DIR/baseref" ;;
  "run list")  cat "$STUB_DIR/runs" ;;
  *)           echo "unexpected gh: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$BIN/gh"

# Exits 0 unless the spec it is given is named in CI_FAIL. Records what it was
# asked, so the test can assert the *second* question is asked at all — the one
# a blunt implementation forgets.
cat > "$BIN/ci-status.sh" <<'STUB'
#!/usr/bin/env bash
spec=""
while (( $# )); do [[ "$1" == "--run" ]] && { shift; spec="$1"; }; shift; done
echo "$spec" >> "$STUB_DIR/ASKED"
for bad in ${CI_FAIL:-}; do [[ "$spec" == "$bad" ]] && exit 1; done
exit 0
STUB
chmod +x "$BIN/ci-status.sh"

export PATH="$BIN:$PATH"
export STUB_DIR="$DIR"
export CI_STATUS="$BIN/ci-status.sh"

reset() {
  rm -f "$DIR/MERGED" "$DIR/ASKED"
  : > "$DIR/ASKED"
  printf '%s' '{"number":9,"headRefName":"301-x","headRefOid":"aaaaaaaaaaaa","baseRefName":"release/0.7.3","state":"OPEN","isDraft":false}' > "$DIR/pr.json"
  printf 'bbbbbbbbbbbb\n' > "$DIR/baseref"
  printf 'pull_request\t301-x\npush\trelease/0.7.3\n' > "$DIR/runs"
  unset CI_FAIL
}

check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }

run() { rc=0; out="$("$SCRIPT" "$@" 2>&1)" || rc=$?; }
merged() { [ -f "$DIR/MERGED" ] && echo yes || echo no; }

echo "merge-to-release.sh"

# --- the happy path, and that it asks both questions -------------------------
reset; run 9
check "a green PR onto a green tip merges"        "0"   "$rc"
check "and the merge was actually reached"        "yes" "$(merged)"
check "it asks about the pull request"            "yes" "$(grep -qx 'pull_request' "$DIR/ASKED" && echo yes || echo no)"
check "it asks about the release branch tip"      "yes" "$(grep -qx 'push:release/0.7.3' "$DIR/ASKED" && echo yes || echo no)"

# --- a red incoming pull request ---------------------------------------------
reset; CI_FAIL="pull_request" run 9
check "a red pull request is refused"             "1"   "$rc"
check "and nothing is merged"                     "no"  "$(merged)"

# --- a red tip: the case a blunt implementation misses ------------------------
reset; CI_FAIL="push:release/0.7.3" run 9
check "a green PR onto a RED tip is refused"      "1"   "$rc"
check "and nothing is merged"                     "no"  "$(merged)"

# --- absence is never a silent pass — R5 --------------------------------------
reset; printf 'push\trelease/0.7.3\n' > "$DIR/runs"; run 9
check "a missing pull-request run refuses"        "1"   "$rc"
check "and says so out loud"                      "yes" "$(grep -q 'No .* run for' <<<"$out" && echo yes || echo no)"
check "and nothing is merged"                     "no"  "$(merged)"

reset; printf 'pull_request\t301-x\n' > "$DIR/runs"; run 9
check "a missing run for the tip refuses"         "1"   "$rc"
check "and nothing is merged"                     "no"  "$(merged)"

reset; printf 'push\trelease/0.7.3\n' > "$DIR/runs"; run 9 --allow-missing-run
check "--allow-missing-run proceeds"              "0"   "$rc"
check "and still says the run was absent"         "yes" "$(grep -q 'No .* run for' <<<"$out" && echo yes || echo no)"

# --- a run for the wrong branch is not this branch's run ----------------------
reset; printf 'pull_request\t301-x\npush\tmain\n' > "$DIR/runs"; run 9
check "a push run on main is not the tip's run"   "1"   "$rc"

# --- guards -------------------------------------------------------------------
reset; printf '%s' '{"number":9,"headRefName":"301-x","headRefOid":"aaaaaaaaaaaa","baseRefName":"main","state":"OPEN","isDraft":false}' > "$DIR/pr.json"
run 9
check "a pull request onto main is refused"       "1"   "$rc"
check "and nothing is merged"                     "no"  "$(merged)"

reset; printf '%s' '{"number":9,"headRefName":"301-x","headRefOid":"aaaaaaaaaaaa","baseRefName":"release/0.7.3","state":"OPEN","isDraft":true}' > "$DIR/pr.json"
run 9
check "a draft is refused"                        "1"   "$rc"

reset; printf '%s' '{"number":9,"headRefName":"301-x","headRefOid":"aaaaaaaaaaaa","baseRefName":"release/0.7.3","state":"MERGED","isDraft":false}' > "$DIR/pr.json"
run 9
check "an already-merged pull request is refused" "1"   "$rc"

reset; run 9 --check-only
check "--check-only passes the checks"            "0"   "$rc"
check "and does not merge"                        "no"  "$(merged)"

reset; run notanumber
check "a non-numeric argument is a usage error"   "2"   "$rc"

echo
# --- the merge strategy, which decides whether the tested SHA is the landed one
#
# `--rebase` rewrites the pull request's commits onto the base. #338 was tested
# as `21d40b2` and landed as `fa25f7a` with a different tree, so its run proved
# a commit that never existed on the release branch — and the rewritten commit
# then failed `check-commit-stamp.sh`, because the stamp is read from the tree
# at that commit and the rebase had moved it onto a newer one.
#
# A merge preserves each commit's tree, so stamps survive and project branches
# stay on `main` rather than being rebased onto the release branch, which is
# what made descoping one package expensive.
#
# `MERGED` records the whole call so the strategy can be asserted. It recorded
# only that a merge happened until 2026-09-09, which is why the wrong strategy
# went unnoticed.
reset; run 9
check "the merge is a merge"                      "yes" \
  "$(grep -q -- '--merge' "$DIR/MERGED" && echo yes || echo "no — got: $(cat "$DIR/MERGED")")"
check "and never a rebase"                        "yes" \
  "$(grep -q -- '--rebase' "$DIR/MERGED" && echo 'no — a rebase rewrites the tested commit' || echo yes)"
check "and the branch is still deleted"           "yes" \
  "$(grep -q -- '--delete-branch' "$DIR/MERGED" && echo yes || echo no)"

if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
