#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's placeholder-milestone check — the mirror image of the
# "nothing mentions this" half of the milestone gate (#265 R2, from #260).
#
# The half that matters is the **quiet** one: an issue sitting in `patch` that
# this release does not touch is next release's work, in the right place, and
# saying so would train somebody to ignore the gate.
#
# Written because the requirement it implements reached a merged delivery
# without being built. Nothing compared what shipped against the project's own
# scope, and no test could have: the gate is only reachable by deploying, which
# is how #150 survived in the code beside it. Hence a function, and hence this.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

# shellcheck source=/dev/null
DEPLOY_SH_FUNCTIONS_ONLY=1 source "$HERE/deploy.sh"

setup() {
  DIR="$(mktemp -d)"; BIN="$DIR/bin"; mkdir -p "$BIN"
  # `gh issue list --milestone X` answers from a per-milestone variable, so a
  # test can put an issue in one placeholder and not the others.
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"--milestone patch"*) printf '%s\n' "${PATCH_ISSUES:-}" ;;
  *"--milestone minor"*) printf '%s\n' "${MINOR_ISSUES:-}" ;;
  *"--milestone major"*) printf '%s\n' "${MAJOR_ISSUES:-}" ;;
  *"--milestone no-release"*) printf '%s\n' "${NO_RELEASE_ISSUES:-}" ;;
  *)                     : ;;
esac
STUB
  chmod +x "$BIN/gh"
  # **Stubbed at the function, not at git.** This suite tests which issues
  # placeholder_shipping names, given which ones the release mentions. How a
  # mention is recognised is the model's (`board/refs.py`, #421) and tested
  # there. The stub used to mimic `git rev-list --grep` with the trailer
  # pattern's exact shape, and went stale twice when that implementation
  # changed; answering at `commits_mentioning` cannot.
  commits_mentioning() {
    local n
    for n in ${MENTIONED:-}; do [[ "$2" == "$n" ]] && { echo 1; return; }; done
    echo 0
  }
  PATH="$BIN:$PATH"
  unset PATCH_ISSUES MINOR_ISSUES MAJOR_ISSUES MENTIONED 2>/dev/null || true
}
teardown() { rm -rf "$DIR"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; echo "     wanted: $2"; echo "     got:    $3"; failures=$((failures + 1)); fi
}
says() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }

# --- the quiet case, which matters most --------------------------------------
setup
PATCH_ISSUES="$(printf '260\tA change can ship under a placeholder')"
MENTIONED=""
export PATCH_ISSUES MENTIONED
check "an untouched issue in patch is silent" "" "$(placeholder_shipping abc123)"
teardown

# --- the case it exists for ---------------------------------------------------
setup
PATCH_ISSUES="$(printf '260\tA change can ship under a placeholder')"
MENTIONED="260"
export PATCH_ISSUES MENTIONED
out="$(placeholder_shipping abc123)"
check "an issue this release mentions is named"  "yes" "$(says "$out" "#260")"
check "and says which placeholder it is in"      "yes" "$(says "$out" "FILED UNDER patch")"
teardown

# --- all three placeholders are looked at ------------------------------------
setup
MINOR_ISSUES="$(printf '301\tSomething in minor')"
MAJOR_ISSUES="$(printf '302\tSomething in major')"
MENTIONED="301 302"
export MINOR_ISSUES MAJOR_ISSUES MENTIONED
out="$(placeholder_shipping abc123)"
check "minor is checked too" "yes" "$(says "$out" "FILED UNDER minor")"
check "and major"            "yes" "$(says "$out" "FILED UNDER major")"
teardown

# --- an empty placeholder is not an error ------------------------------------
setup
MENTIONED="260"; export MENTIONED
check "no placeholder issues at all is silent" "" "$(placeholder_shipping abc123)"
teardown

# --- one mentioned among several ---------------------------------------------
# The gate must name the one that is shipping, not the whole milestone.
setup
PATCH_ISSUES="$(printf '260\tShipping now\n261\tNot this time\n262\tAlso not')"
MENTIONED="260"
export PATCH_ISSUES MENTIONED
out="$(placeholder_shipping abc123)"
check "only the mentioned one is named" "1" "$(printf '%s' "$out" | grep -c '#')"
check "and it is the right one"         "yes" "$(says "$out" "#260")"
teardown

# --- no-release, the placeholder everything is actually in -------------------
# 5 open and 60 closed on 2026-09-01, against none in the other three. Both
# projects shipping in 0.7.1 were filed under it, the gate said nothing, and the
# milestone was corrected by hand on the morning of the deploy. #281.
setup
NO_RELEASE_ISSUES="$(printf '303\tA project shipping while filed under no-release')"
MENTIONED="303"
export NO_RELEASE_ISSUES MENTIONED
out="$(placeholder_shipping abc123)"
check "an issue shipping from no-release is named" "yes" "$(says "$out" "#303")"
check "and says which placeholder it is in"        "yes" "$(says "$out" "FILED UNDER no-release")"
teardown

# The quiet half: filed under no-release and not shipping, which is most of them.
setup
NO_RELEASE_ISSUES="$(printf '303\tA project nobody is shipping')"
MENTIONED=""
export NO_RELEASE_ISSUES MENTIONED
check "an untouched issue in no-release is silent" "" "$(placeholder_shipping abc123)"
teardown

if (( failures )); then echo; echo "$failures test(s) failed" >&2; exit 1; fi
echo
echo "All placeholder-milestone checks passed."
