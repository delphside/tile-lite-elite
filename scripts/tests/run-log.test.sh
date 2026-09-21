#!/usr/bin/env bash
set -euo pipefail

# run-log.test.sh — #328's record, under the same `set -euo pipefail` the
# scripts it serves run with.
#
# The case that matters is a script that **fails**: it does not reach its own
# last line, so the exit status is recorded by a trap rather than by the caller
# remembering. 0.7.2 is why — the deploy exited 1 having printed every success
# line, and both facts were in the terminal and nowhere else.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then echo "  ok   $name"
  else echo "  FAIL $name: wanted '$want', got '$got'"; failures=$((failures + 1)); fi
}

# A script that fails part-way, as a deploy does.
cat > "$STATE/failing.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
. "$HERE/run-log.sh"
run_log_start failing.sh one two
echo "human output"
run_log_event "gate" "gate=schema" "result=passed"
exit 7
INNER
chmod +x "$STATE/failing.sh"

out="$(XDG_STATE_HOME="$STATE" bash "$STATE/failing.sh" 2>&1)" && status=0 || status=$?
check "the script's own exit status is unchanged" 7 "$status"
check "and its human output is untouched" "human output" "$out"

file="$(ls -1 "$STATE/tile-lite-elite/failing-"*.jsonl 2>/dev/null | head -1)"
check "a record was written" "yes" "$([[ -n "$file" ]] && echo yes || echo no)"

check "the failure is recorded, not lost with the terminal" "yes" \
  "$(grep -q '"message":"run finished","script":"failing.sh","status":"7"' "$file" && echo yes || echo no)"
check "the run's arguments are kept" "yes" \
  "$(grep -q '"args":"one two"' "$file" && echo yes || echo no)"
check "an event written before the failure survives" "yes" \
  "$(grep -q '"gate":"schema"' "$file" && echo yes || echo no)"

check "every line is JSON" "yes" \
  "$(python3 -c "
import json,sys
for line in open('$file'):
    json.loads(line)
print('yes')" 2>/dev/null)"

# **A value with a quote must not break the line format**, or the record stops
# being machine-readable exactly when something unusual happened.
cat > "$STATE/quoting.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
. "$HERE/run-log.sh"
run_log_start quoting.sh
run_log_event "odd" 'text=he said "no" \ and stopped'
INNER
chmod +x "$STATE/quoting.sh"
XDG_STATE_HOME="$STATE" bash "$STATE/quoting.sh" >/dev/null 2>&1
qfile="$(ls -1 "$STATE/tile-lite-elite/quoting-"*.jsonl | head -1)"
check "quotes and backslashes in a value stay parseable" "yes" \
  "$(python3 -c "
import json
for line in open('$qfile'):
    json.loads(line)
print('yes')" 2>/dev/null)"

# Per script, so a busy deploy week does not evict the last restore.
cat > "$STATE/keep.sh" <<INNER
#!/usr/bin/env bash
. "$HERE/run-log.sh"
run_log_start keep.sh
INNER
chmod +x "$STATE/keep.sh"
for _ in 1 2 3 4 5; do XDG_STATE_HOME="$STATE" RUN_LOG_KEEP=3 bash "$STATE/keep.sh" >/dev/null 2>&1; sleep 0.01; done
kept="$(ls -1 "$STATE/tile-lite-elite/keep-"*.jsonl 2>/dev/null | wc -l)"
check "pruned to the last few, per script" "yes" "$([[ "$kept" -le 4 ]] && echo yes || echo no)"
check "and another script's records are untouched" "yes" \
  "$([[ -n "$(ls -1 "$STATE/tile-lite-elite/failing-"*.jsonl 2>/dev/null)" ]] && echo yes || echo no)"

# **A caller's own EXIT trap must not lose the outcome.** deploy.sh sets one
# 1,300 lines after it sources this, and an unchained trap there would silently
# drop the result of every deploy -- the one run this exists for.
cat > "$STATE/trapped.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
. "$HERE/run-log.sh"
cleanup() { echo "cleanup ran"; }
run_log_start trapped.sh
trap 'st=\$?; cleanup; run_log_finish \$st' EXIT
exit 5
INNER
chmod +x "$STATE/trapped.sh"
tout="$(XDG_STATE_HOME="$STATE" bash "$STATE/trapped.sh" 2>&1)" || true
tfile="$(ls -1 "$STATE/tile-lite-elite/trapped-"*.jsonl | head -1)"
check "a chained trap still runs the caller's cleanup" "cleanup ran" "$tout"
check "and still records the outcome" "yes" \
  "$(grep -q '"status":"5"' "$tfile" && echo yes || echo no)"

# The other direction: a trap set *before* run_log_start is kept, not replaced.
cat > "$STATE/pretrap.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
. "$HERE/run-log.sh"
trap 'echo "earlier trap ran"' EXIT
run_log_start pretrap.sh
exit 4
INNER
chmod +x "$STATE/pretrap.sh"
pout="$(XDG_STATE_HOME="$STATE" bash "$STATE/pretrap.sh" 2>&1)" || true
pfile="$(ls -1 "$STATE/tile-lite-elite/pretrap-"*.jsonl | head -1)"
check "an earlier trap is chained, not clobbered" "earlier trap ran" "$pout"
check "and the outcome is recorded too" "yes" \
  "$(grep -q '"status":"4"' "$pfile" && echo yes || echo no)"

echo
if (( failures )); then echo "$failures failure(s)"; exit 1; fi
echo "run-log: all cases pass"
