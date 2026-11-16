#!/usr/bin/env bats

# post-disk-metrics.sh and record-restore-drill.sh, with the clock, df and
# post-metric.sh stubbed. post-metric.sh is a stub beside a copy of the script,
# which finds it by its own directory, recording each call.
#
# The restore-drill alarm fires above 100 days, so the boundary is the case that
# matters: 100 days must post 100 and 101 must post 101. And a host with no
# recorded drill must post a figure far above it, because an alarm that waits for
# a datapoint never fires on a host that never had one (#224).

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/ops"
  cp "$BATS_TEST_DIRNAME/../operate/post-disk-metrics.sh" \
     "$BATS_TEST_DIRNAME/../operate/record-restore-drill.sh" "$D/ops/"
  # Records every call, and fails the metric named in POST_FAIL.
  cat > "$D/ops/post-metric.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$D/posts"
[[ "\${POST_FAIL:-}" != "\$1" ]]
STUB
  chmod +x "$D/ops/post-metric.sh"
  # 70 of 100 bytes available: 70.0% free.
  cat > "$D/bin/df" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DF_ARGS_FILE:-/dev/null}"
[[ -z "${DF_FAIL:-}" ]] || exit 1
printf '    Avail  1B-blocks\n%s\n' "${DF_LINE:-70 100}"
STUB
  # Only the epoch reading is stubbed; anything else is the real date.
  cat > "$D/bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "-u +%s" ]]; then echo "$NOW"; else exec /usr/bin/env -i /bin/date "$@"; fi
STUB
  chmod +x "$D/bin/df" "$D/bin/date"
  export NOW=1800000000
  export DRILL_FILE="$D/drill"
  export HOME="$D"
}

disk() { run env PATH="$D/bin:$PATH" bash "$D/ops/post-disk-metrics.sh" "$@"; }
record() { run env PATH="$D/bin:$PATH" bash "$D/ops/record-restore-drill.sh" "$@"; }

drill_days_ago() { echo $(( NOW - $1 * 86400 - ${2:-0} )) > "$DRILL_FILE"; }

@test "DiskFreePercent is posted with the mount dimension" {
  disk
  assert_success
  assert_equal "$(grep '^DiskFreePercent' "$D/posts")" "DiskFreePercent 70.0 mount=/"
}

@test "the mount is the one asked for, in both the measurement and the dimension" {
  export DF_ARGS_FILE="$D/df-args"
  MOUNT=/data disk
  assert_success
  assert_equal "$(grep '^DiskFreePercent' "$D/posts")" "DiskFreePercent 70.0 mount=/data"
  run grep -c -- '/data' "$D/df-args"
  assert_output 1
}

@test "free space is the available share of the total, to a decimal" {
  DF_LINE="333 1000" disk
  assert_equal "$(grep '^DiskFreePercent' "$D/posts")" "DiskFreePercent 33.3 mount=/"
}

@test "a drill 100 days ago posts 100" {
  drill_days_ago 100
  disk
  assert_success
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 100"
}

@test "a drill 101 days ago posts 101" {
  drill_days_ago 101
  disk
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 101"
}

@test "whole days: a second short of 101 days is still 100" {
  drill_days_ago 101 -1
  disk
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 100"
}

@test "a drill today posts 0" {
  drill_days_ago 0
  disk
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 0"
}

# The existence case: a rebuilt host has never had a drill.
@test "no recorded drill posts 9999, so the threshold alarm fires" {
  assert [ ! -e "$DRILL_FILE" ]
  disk
  assert_success
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 9999"
}

@test "an unreadable record posts 9999 with a warning, not a silent zero" {
  echo "yesterday" > "$DRILL_FILE"
  disk
  assert_success
  assert_output --partial "warning"
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 9999"
}

@test "a failed disk post still posts the drill age, and the run fails" {
  POST_FAIL=DiskFreePercent disk
  assert_equal "$status" 1
  run grep -c '^RestoreDrillAgeDays' "$D/posts"
  assert_output 1
}

@test "a disk that cannot be measured posts nothing and exits 2" {
  DF_FAIL=1 disk
  assert_equal "$status" 2
  assert_output --partial "cannot read free space"
  assert [ ! -e "$D/posts" ]
}

@test "record-restore-drill.sh records the time as epoch seconds, and the disk job reads it back" {
  record
  assert_success
  assert_equal "$(cat "$DRILL_FILE")" "$NOW"
  NOW=$(( NOW + 3 * 86400 )) disk
  assert_equal "$(grep '^RestoreDrillAgeDays' "$D/posts")" "RestoreDrillAgeDays 3"
}

@test "recording again replaces the time" {
  drill_days_ago 90
  record
  assert_equal "$(cat "$DRILL_FILE")" "$NOW"
}

@test "the record goes in the home directory by default" {
  unset DRILL_FILE
  record
  assert_success
  assert_equal "$(cat "$D/.tile-lite-elite-restore-drill")" "$NOW"
}

@test "a record that cannot be written is an error" {
  DRILL_FILE="$D/no-such-dir/drill" record
  assert_equal "$status" 2
  assert_output --partial "cannot record the drill"
}
