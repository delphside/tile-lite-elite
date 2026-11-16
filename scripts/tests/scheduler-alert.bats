#!/usr/bin/env bats

# scheduler-alert.sh, against a stub journalctl holding a journal the test
# appends to, and a stub post-metric.sh beside a copy of the script.
#
# The stub journalctl honours the two ways the script reads: `--after-cursor=C`
# gives the entries after C, and `--since` gives the entries written in the last
# ten minutes. Each entry carries the application's own JSON line in MESSAGE,
# which is how the `journald` logging driver stores it, and a __CURSOR.
#
# `-n 1` gives the latest entry. What matters is across runs: a failure is posted once, not again, and a line
# between two runs is not missed (#224 R4).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/ops"
  cp "$BATS_TEST_DIRNAME/../operate/scheduler-alert.sh" "$D/ops/"
  cat > "$D/ops/post-metric.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$D/posts"
exit "\${POST_EXIT:-0}"
STUB
  cat > "$D/bin/journalctl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$D/journalctl-calls"
[[ -z "\${JOURNAL_FAIL:-}" ]] || exit 1
exec "$(command -v python3)" -I -c '
import json, sys
args = sys.argv[1:]
entries = [json.loads(l) for l in open("$D/journal")] if __import__("os").path.exists("$D/journal") else []
after = [a.split("=", 1)[1] for a in args if a.startswith("--after-cursor=")]
if after:
    cursors = [e["__CURSOR"] for e in entries]
    if after[0] not in cursors:
        sys.exit(1)
    entries = entries[cursors.index(after[0]) + 1:]
elif "-n" in args:
    entries = entries[-int(args[args.index("-n") + 1]):]
elif "--since" in args:
    entries = [e for e in entries if e["_AGE_MIN"] <= 10]
for e in entries:
    print(json.dumps(e))
' "\$@"
STUB
  chmod +x "$D/ops/post-metric.sh" "$D/bin/journalctl"
  export CURSOR_FILE="$D/cursor"
  export HOME="$D"
  N=0
}

# journal <age-minutes> <level> <target> <message>: one application line.
journal() {
  N=$((N + 1))
  "$(command -v python3)" -I -c '
import json, sys
age, level, target, message, n, out = sys.argv[1:]
event = {"timestamp": "2026-11-16T10:00:00Z", "level": level, "target": target, "message": message, "job": "x"}
with open(out, "a") as f:
    f.write(json.dumps({"__CURSOR": "c" + n, "_AGE_MIN": float(age), "MESSAGE": json.dumps(event)}) + "\n")
' "$1" "$2" "$3" "$4" "$N" "$D/journal"
}

alert() { run env PATH="$D/bin:$PATH" bash "$D/ops/scheduler-alert.sh"; }
posts() { if [[ -e "$D/posts" ]]; then wc -l < "$D/posts"; else echo 0; fi; }

@test "a panicked job posts JobFailed job=scheduler" {
  journal 2 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_success
  assert_equal "$(cat "$D/posts")" "JobFailed 1 job=scheduler"
}

@test "a stalled job, logged from the jobs module, posts too" {
  journal 2 ERROR server_game::app::scheduler_jobs "job appears stalled"
  alert
  assert_success
  assert_equal "$(posts)" 1
}

@test "a quiet run posts nothing" {
  journal 2 INFO server_game::app::scheduler "pass complete"
  journal 3 INFO server_game::app::auth "player registered"
  alert
  assert_success
  assert_equal "$(posts)" 0
}

@test "an empty journal posts nothing and saves no cursor" {
  alert
  assert_success
  assert_equal "$(posts)" 0
  assert [ ! -e "$CURSOR_FILE" ]
}

@test "other errors, and other targets, do not match" {
  journal 1 ERROR server_game::app::auth "job panicked"
  journal 2 WARN server_game::app::scheduler "job appears stalled"
  journal 3 ERROR server_game::app::scheduler "something else"
  alert
  assert_equal "$(posts)" 0
}

@test "a line that is not JSON is skipped, not fatal" {
  printf '%s\n' '{"__CURSOR":"c0","_AGE_MIN":1,"MESSAGE":"not json at all"}' > "$D/journal"
  alert
  assert_success
  assert_equal "$(posts)" 0
}

@test "one match is posted once and not again at the next run" {
  journal 2 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_equal "$(posts)" 1
  alert
  assert_success
  assert_equal "$(posts)" 1
}

@test "a line between two runs is not missed" {
  journal 5 INFO server_game::app::scheduler "pass complete"
  alert
  assert_equal "$(posts)" 0
  journal 4 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_equal "$(posts)" 1
  journal 1 ERROR server_game::app::scheduler_jobs "job appears stalled"
  alert
  assert_equal "$(posts)" 2
}

@test "several matches in one run post once" {
  journal 3 ERROR server_game::app::scheduler "job panicked"
  journal 2 ERROR server_game::app::scheduler_jobs "job appears stalled"
  alert
  assert_equal "$(posts)" 1
}

@test "a first run with no cursor reads the last 10 minutes, and saves a cursor" {
  journal 30 ERROR server_game::app::scheduler "job panicked"
  journal 9 INFO server_game::app::auth "player registered"
  alert
  assert_success
  assert_equal "$(posts)" 0
  # The look-back is the timer's interval, ten minutes, by the argument itself.
  run grep -c -- '--since 10 minutes ago' "$D/journalctl-calls"
  assert_output 1
  assert_equal "$(cat "$CURSOR_FILE")" c2
}

# The gap: a first run that finds nothing in its window must still leave a
# cursor, so a line written before the second run is read from there.
@test "a quiet first run saves the latest entry's cursor, so a later line is not missed" {
  journal 40 INFO server_game::app::auth "player registered"
  alert
  assert_equal "$(posts)" 0
  assert_equal "$(cat "$CURSOR_FILE")" c1
  journal 25 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_equal "$(posts)" 1
  run grep -c -- '--after-cursor=c1' "$D/journalctl-calls"
  assert_output 1
}

@test "only the scheduler's two messages match, whatever else it logs at ERROR" {
  journal 2 ERROR server_game::app::scheduler "job queue closed"
  alert
  assert_equal "$(posts)" 0
}

@test "a failed post exits with post-metric.sh's own status" {
  journal 1 ERROR server_game::app::scheduler "job panicked"
  POST_EXIT=75 alert
  assert_equal "$status" 75
}

@test "a first run posts a failure inside its window" {
  journal 9 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_equal "$(posts)" 1
}

@test "a run after a saved cursor reads after it, not by time" {
  journal 2 INFO server_game::app::auth "player registered"
  alert
  alert
  run grep -c -- '--after-cursor=c1' "$D/journalctl-calls"
  assert_output 1
}

@test "a failed post keeps the cursor, so the next run retries" {
  journal 2 INFO server_game::app::auth "player registered"
  alert
  journal 1 ERROR server_game::app::scheduler "job panicked"
  POST_EXIT=75 alert
  assert_equal "$status" 75
  assert_output --partial "will retry"
  assert_equal "$(cat "$CURSOR_FILE")" c1
  alert
  assert_success
  assert_equal "$(posts)" 2
  assert_equal "$(cat "$CURSOR_FILE")" c2
}

@test "a cursor the journal no longer holds falls back to the last 10 minutes" {
  echo "gone" > "$CURSOR_FILE"
  journal 2 ERROR server_game::app::scheduler "job panicked"
  alert
  assert_success
  assert_output --partial "not usable"
  assert_equal "$(posts)" 1
  assert_equal "$(cat "$CURSOR_FILE")" c1
}

@test "an unreadable journal exits 2 and posts nothing" {
  JOURNAL_FAIL=1 alert
  assert_equal "$status" 2
  assert_output --partial "cannot read the journal"
  assert_equal "$(posts)" 0
}

@test "the application's own journal is the one read" {
  alert
  # Every call names the tag: none reads the whole journal.
  run grep -c -v 'CONTAINER_TAG=tle-server' "$D/journalctl-calls"
  assert_output 0
}
