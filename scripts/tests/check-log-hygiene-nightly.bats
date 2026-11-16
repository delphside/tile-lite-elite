#!/usr/bin/env bats

# check-log-hygiene-nightly.sh, with a stub journalctl and a stub post-metric.sh
# beside a copy of the script, and the real validator and schema. The metric is
# on the clean path only: a dirty run, which exits 1 and writes its exceptions,
# posts nothing, and that silence is what the alarm watches for (#224 R1).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/ops"
  cp "$BATS_TEST_DIRNAME/../operate/check-log-hygiene-nightly.sh" \
     "$BATS_TEST_DIRNAME/../operate/check-log-hygiene.py" \
     "$BATS_TEST_DIRNAME/../../docs/4.4.7-log-events.md" "$D/ops/"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/posts"\nexit "${POST_EXIT:-0}"\n' "$D" > "$D/ops/post-metric.sh"
  printf '#!/usr/bin/env bash\ncat "%s/journal"\n' "$D" > "$D/bin/journalctl"
  chmod +x "$D/ops/post-metric.sh" "$D/bin/journalctl"
  export EXCEPTIONS="$D/exceptions.log"
  export HOME="$D"
}

nightly() { run env PATH="$D/bin:$PATH" bash "$D/ops/check-log-hygiene-nightly.sh"; }

@test "a clean run posts JobSucceeded job=logcheck once and uploads no marker" {
  : > "$D/journal"
  nightly
  assert_success
  assert_equal "$(cat "$D/posts")" "JobSucceeded 1 job=logcheck"
  run grep -c "marker-" "$D/ops/check-log-hygiene-nightly.sh"
  assert_output 0
}

@test "a dirty run fails, writes its exceptions, and posts nothing" {
  echo '{"timestamp":"2026-08-21T19:11:15Z","level":"INFO","message":"x","target":"t","email":"a@b.com"}' > "$D/journal"
  nightly
  assert_equal "$status" 1
  assert [ ! -e "$D/posts" ]
  run grep -c EXCEPTIONS "$EXCEPTIONS"
  assert_output 1
}

@test "a clean run whose post fails fails" {
  : > "$D/journal"
  POST_EXIT=1 nightly
  assert_failure
}
