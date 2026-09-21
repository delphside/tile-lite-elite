#!/usr/bin/env bash
set -euo pipefail

# Tests verify.sh's transition check, under the same `set -euo pipefail`
# verify.sh runs with.
#
# The behaviour it pins is the contract, not the wording: **this check never
# fails.** `board-check.py` reports and does not refuse — a field is
# changed in a browser and nothing can stand in front of that — so surfacing it
# through verify.sh must not put the deploy path's trusted exit status at the
# mercy of bookkeeping. Every case below asserts `note` or `pass`, and case 5
# asserts the negative directly.
#
# Exit 2 is the case worth having: it is "no gh or jq", not "nothing is wrong".
# Reporting it as a pass is the shape that let 0.5.0 through the release gate —
# absence read as success — so it is tested separately from a clean run.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

# Runs verify.sh's transition check alone against a stubbed
# `scripts/board-check.py` (R4), which replaced check-transitions.sh on
# 2026-09-19. The exit contract is the same: 0 clean, 2 could not run,
# anything else findings.
#   $1  the exit status the stub returns
#   $2  what the stub prints
#   $3  optional: "timeout" to stub `timeout` itself as having killed it,
#       which tests that branch without waiting 60 seconds for it
run_transitions() {
  local status="$1" output="$2" mode="${3:-}" work
  work="$(mktemp -d)"
  mkdir -p "$work/scripts" "$work/bin"
  printf '%s' "$output" > "$work/out"

  cat > "$work/scripts/board-check.py" <<STUB
#!/usr/bin/env bash
cat "$work/out"
exit $status
STUB
  chmod +x "$work/scripts/board-check.py"

  if [[ "$mode" == "timeout" ]]; then
    # `timeout` exits 124 when it kills its child. Stubbing it is the only way
    # to reach that branch without the test taking a minute.
    cat > "$work/bin/timeout" <<'STUB'
#!/usr/bin/env bash
exit 124
STUB
    chmod +x "$work/bin/timeout"
  fi

  (
    cd "$work"
    PATH="$work/bin:$PATH"
    # shellcheck disable=SC1090
    source <(sed -n '/^check_transitions()/,/^}/p' "$HERE/scripts/verify.sh")
    # Mirroring the real three-argument signature: the detail lines are what a
    # reader acts on, and a stub that drops them tests something other than the
    # code.
    pass() { printf 'PASS %s\n%s\n' "$2" "${3:-}"; }
    fail() { printf 'FAIL %s\n%s\n' "$2" "${3:-}"; }
    note() { printf 'NOTE %s\n%s\n' "$2" "${3:-}"; }
    declare -A LABEL
    check_transitions
  )
  rm -rf "$work"
}

echo "verify-transitions"

# 1 — findings are a note, and the issues are named
out="$(run_transitions 1 'ISSUE COMPLETENESS  R4 - each issue against its type and step
#309 Requirement at On Hold  The machine account token expires
    !!  something named under dependencies

Totals  160 met  1 missing  8 not checked
')"
check "findings report as a note"        "NOTE" "$(awk '{print $1; exit}' <<< "$out")"
check "the issue is named in the detail" "1"    "$(grep -c '#309' <<< "$out")"

# 1b — a section finding, which is not a `#N` line
# The milestone check moved into board-check.py on 2026-09-21 and reports like
# the other release-scoped sections, `  !! #N ...`. A detail filter that took
# only `#N` lines turned the summary red and printed nothing under it.
out="$(run_transitions 1 'MILESTONE  0.8.2 carries only built work
  !! #268 WorkPackage #71 WP A: Core Game Lifecycle  no commit mentions this
  !! unbuilt: #268
')"
check "a section finding reaches the detail" "1" "$(grep -c 'no commit mentions this' <<< "$out")"

# 2 — the quiet case
out="$(run_transitions 0 'ISSUE COMPLETENESS  R4 - each issue against its type and step

  every open issue has done the work its field claims
')"
check "a clean run passes" "PASS" "$(awk '{print $1; exit}' <<< "$out")"

# 3 — exit 2 is "could not run", never a pass
out="$(run_transitions 2 'check-transitions: no '"'"'gh'"'"' on PATH')"
check "a missing tool is not a pass" "NOTE" "$(awk '{print $1; exit}' <<< "$out")"
check "and says it could not run"    "1"    "$(grep -c 'could not run' <<< "$out")"

# 4 — a timeout is a note, not a failure
out="$(run_transitions 1 'irrelevant' timeout)"
check "a timeout reports as a note" "NOTE" "$(awk '{print $1; exit}' <<< "$out")"
check "and says it timed out"       "1"    "$(grep -c 'timed out' <<< "$out")"

# 5 — the contract, asserted directly: no outcome fails
for st in 0 1 2 3; do
  out="$(run_transitions "$st" 'anything at all')"
  check "exit $st never produces a FAIL" "0" "$(grep -c '^FAIL' <<< "$out")"
done

echo
if (( failures > 0 )); then
  echo "  $failures check(s) failed"
  exit 1
fi
echo "  all checks passed"
