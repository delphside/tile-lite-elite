#!/usr/bin/env bash
set -euo pipefail

# board-practices.test.sh — #407 R3: which activities are overdue.
#
# Against real files copied to a temp directory, not stubs — the parser reads
# an actual markdown table and an actual CSV, so the test should too. Every
# case here was run for real against the live register and log while this
# script was built, and is reproduced as an assertion.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/register.md" <<'REG'
| id | activity | frequency (days) | owner | produces | ITIL practice |
| --- | --- | --- | --- | --- | --- |
| `capacity-plan` | Produce and review the capacity plan | 30 | Claude produces, owner reviews | a report | Capacity and performance management |
| `benchmark-run` | Run the engine timing benchmark | 30 | Claude | a row | Capacity and performance management |
| `never-done` | Something with no log row | 7 | Claude | nothing | test only |
REG

TODAY="$(date +%Y-%m-%d)"
OLD="$(date -d '90 days ago' +%Y-%m-%d 2>/dev/null || date -v-90d +%Y-%m-%d)"
RECENT="$(date -d '2 days ago' +%Y-%m-%d 2>/dev/null || date -v-2d +%Y-%m-%d)"

cat > "$DIR/log.csv" <<CSV
date,activity,who,note
$OLD,benchmark-run,Claude,old run
$RECENT,capacity-plan,Claude,recent report
CSV

run() {
  REGISTER_OVERRIDE="$DIR/register.md" LOG_OVERRIDE="$DIR/log.csv" \
    python3 "$HERE/board-practices.py" "$@"
}

failures=0
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }

echo "board-practices.py"

# --- the overdue case -------------------------------------------------------
out="$(run)"
check "a 90-day-old benchmark run against a 30-day frequency is overdue" \
  "1" "$(grep -c 'benchmark-run.*OVERDUE' <<< "$out")"
check "a 2-day-old capacity plan against 30 days is not" \
  "0" "$(grep -c 'capacity-plan.*OVERDUE' <<< "$out")"
check "an activity with no log row reads never logged, not overdue" \
  "1" "$(grep -c 'never-done.*never logged' <<< "$out")"

# --- --exit-code -------------------------------------------------------------
run --exit-code > /dev/null 2>&1 && rc=0 || rc=$?
check "--exit-code is non-zero when something is overdue" "1" "$rc"

run > /dev/null 2>&1 && rc=0 || rc=$?
check "the plain form exits 0 even with an overdue activity — it reports" "0" "$rc"

# --- missing sources: D46's 2, and 'cannot tell' not 'nothing outstanding' --
out2="$(REGISTER_OVERRIDE="$DIR/nope.md" LOG_OVERRIDE="$DIR/log.csv" \
  python3 "$HERE/board-practices.py" 2>&1)" && rc2=0 || rc2=$?
check "a missing register is 'could not judge' — D46" "2" "$rc2"
check "and says cannot tell, not nothing outstanding" "1" \
  "$(grep -c 'cannot read' <<< "$out2")"

# --- --json is valid and carries overdue_by ---------------------------------
json="$(run --json)"
check "json parses" "0" \
  "$(python3 -c "import json,sys; json.loads(sys.argv[1])" "$json" > /dev/null 2>&1; echo $?)"
check "the overdue entry's overdue_by is positive" "1" \
  "$(python3 -c "
import json
d = json.loads('''$json''')
print(1 if any((a['overdue_by'] or -1) > 0 for a in d) else 0)
")"

echo
if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
