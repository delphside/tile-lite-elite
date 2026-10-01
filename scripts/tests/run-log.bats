#!/usr/bin/env bats

# run-log.sh, #328's record. The case that matters is a script that fails: it
# does not reach its own last line, so the exit status is recorded by a trap
# rather than by the caller remembering. 0.7.2 is why: the deploy exited 1
# having printed every success line, and both facts were in the terminal and
# nowhere else.
#
# Each case writes a small script that sources run-log.sh under
# `set -euo pipefail` and runs it as its own process, as the real scripts do.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  RUN_LOG="$BATS_TEST_DIRNAME/../application/deliver/run-log.sh"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  LOGS="$XDG_STATE_HOME/tile-lite-elite"
}

script() {   # <name> <body>: a script sourcing run-log.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\n. "%s"\n%s\n' "$RUN_LOG" "$2" > "$BATS_TEST_TMPDIR/$1.sh"
  chmod +x "$BATS_TEST_TMPDIR/$1.sh"
}
record() { ls -1 "$LOGS/$1-"*.jsonl 2>/dev/null | head -1; }
all_json() { python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$1"; }

failing() {
  script failing 'run_log_start failing.sh one two
echo "human output"
run_log_event "gate" "gate=schema" "result=passed"
exit 7'
  run bash "$BATS_TEST_TMPDIR/failing.sh"
}

@test "a failing script keeps its own exit status and its human output" {
  failing
  assert_equal "$status" 7
  assert_output "human output"
}

@test "the failure is recorded, not lost with the terminal" {
  failing
  file="$(record failing)"
  assert [ -n "$file" ]
  run grep -c '"message":"run finished","script":"failing.sh","status":"7"' "$file"
  assert_output 1
  run grep -q '"args":"one two"' "$file"
  assert_success
  # An event written before the failure survives.
  run grep -q '"gate":"schema"' "$file"
  assert_success
  run all_json "$file"
  assert_success
}

# Or the record stops being machine-readable exactly when something unusual happened.
@test "quotes and backslashes in a value stay parseable" {
  script quoting 'run_log_start quoting.sh
run_log_event "odd" '"'"'text=he said "no" \ and stopped'"'"
  run bash "$BATS_TEST_TMPDIR/quoting.sh"
  run all_json "$(record quoting)"
  assert_success
}

# Per script, so a busy deploy week does not evict the last restore.
@test "records are pruned to the last few, per script" {
  failing
  script keep 'run_log_start keep.sh'
  for _ in 1 2 3 4 5; do RUN_LOG_KEEP=3 bash "$BATS_TEST_TMPDIR/keep.sh" >/dev/null 2>&1; sleep 0.01; done
  assert [ "$(ls -1 "$LOGS/keep-"*.jsonl | wc -l)" -le 4 ]
  assert [ -n "$(record failing)" ]
}

# deploy.sh sets its own EXIT trap 1,300 lines after it sources run-log.sh, and
# an unchained trap there would silently drop the result of every deploy.
@test "a caller's own chained EXIT trap still runs, and the outcome is recorded" {
  script trapped 'cleanup() { echo "cleanup ran"; }
run_log_start trapped.sh
trap '"'"'st=$?; cleanup; run_log_finish $st'"'"' EXIT
exit 5'
  run bash "$BATS_TEST_TMPDIR/trapped.sh"
  assert_output "cleanup ran"
  run grep -q '"status":"5"' "$(record trapped)"
  assert_success
}

@test "a trap set before run_log_start is chained, not clobbered" {
  script pretrap 'trap '"'"'echo "earlier trap ran"'"'"' EXIT
run_log_start pretrap.sh
exit 4'
  run bash "$BATS_TEST_TMPDIR/pretrap.sh"
  assert_output "earlier trap ran"
  run grep -q '"status":"4"' "$(record pretrap)"
  assert_success
}
