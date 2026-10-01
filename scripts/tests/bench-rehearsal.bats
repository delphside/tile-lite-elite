#!/usr/bin/env bats

# bench-rehearsal.sh: the parts that do not need the rehearsal host. The script
# runs as its own process, so its own `set -euo pipefail` holds.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../application/measure/bench-rehearsal.sh"
  ROOT="$BATS_TEST_DIRNAME/../.."
}

# The column positions the summary reads. If a column is inserted into the CSV
# and these are not updated, the check prints the wrong numbers confidently.
col() {
  head -1 "$ROOT/crates/server-game/examples/engine_timing_results.csv" \
    | tr ',' '\n' | nl -ba | awk -v n="$1" '$1==n{print $2}'
}

@test "it parses" {
  run bash -n "$SCRIPT"
  assert_success
}

# Too few games is refused before anything is built or copied: a p99 from 411
# samples is four data points, which is what the older 10-game rows had.
#
# cargo, ssh and scp are stubs that record and fail, so a broken guard is
# caught here rather than acted on. Without them, a mutation test of this
# guard on 2026-09-27 built the benchmark and ran ten games on rehearsal.
@test "it refuses fewer than 30 games, before building or copying anything" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  for tool in cargo ssh scp; do
    printf '#!/usr/bin/env bash\necho %s >> "%s/called"\nexit 1\n' "$tool" "$BATS_TEST_TMPDIR" \
      > "$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" 10
  assert_equal "$status" 1
  assert_output --partial "refusing 10 games"
  [ ! -e "$BATS_TEST_TMPDIR/called" ] || fail "it went on to run: $(cat "$BATS_TEST_TMPDIR/called")"
}

# The commit substitution: the VM has no git, so the row comes back saying
# `unknown` and the local commit is put in its place. This is the bug that
# would silently mislabel every remote row.
@test "the unknown commit is replaced, and a real one left alone" {
  ROW="1788,unknown,instance-x,official,30,30,1229,0.08"
  assert_equal "${ROW/,unknown,/,abc1234,}" "1788,abc1234,instance-x,official,30,30,1229,0.08"
  R='1788,def5678,instance-x'
  assert_equal "${R/,unknown,/,abc1234,}" "1788,def5678,instance-x"
}

@test "the columns the summary reads are where it reads them" {
  assert_equal "$(col 3)" host
  assert_equal "$(col 10)" median_ms
  assert_equal "$(col 13)" p95_ms
  assert_equal "$(col 14)" p99_ms
  assert_equal "$(col 21)" cpu_p99_ms
  assert_equal "$(col 24)" steal_pct_of_capacity
  assert_equal "$(col 27)" slow_moves
  assert_equal "$(col 28)" slow_cpu_starved
}

@test "it is registered as a tool" {
  run grep -q 'bench-rehearsal.sh' "$ROOT/docs/3.0-tools.md"
  assert_success
}
