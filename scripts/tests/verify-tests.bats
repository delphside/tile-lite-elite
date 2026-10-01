#!/usr/bin/env bats

# verify.sh's "Tooling tests pass" check. It looped over
# scripts/tests/*.test.sh and skipped what it could not find, so as the suites
# moved to bats on 2026-09-27 each batch dropped out of it unnoticed; with the
# last one gone it would have passed having run nothing. These cases hold it to
# running the two runners, and to failing rather than skipping without bats.
#
# Run against a fixture directory holding one tiny suite of each kind, so the
# check's verdict is about the check, not about the real suites.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  VERIFY="$BATS_TEST_DIRNAME/../application/deliver/verify.sh"
  F="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$F/scripts/tests" "$F/scripts/programme/board/tests"
  suite_bats pass
  suite_python pass
  suite_model pass
}

suite_bats() {   # pass|fail
  local body='[ 1 = 1 ]'; [[ "$1" == fail ]] && body='[ 1 = 2 ]'
  printf '#!/usr/bin/env bats\n@test "one" {\n  %s\n}\n' "$body" > "$F/scripts/tests/one.bats"
}
suite_python() { # pass|fail
  local want=1; [[ "$1" == fail ]] && want=2
  : > "$F/scripts/tests/__init__.py"
  printf 'import unittest\nclass T(unittest.TestCase):\n    def test_one(self):\n        self.assertEqual(1, %s)\n' "$want" \
    > "$F/scripts/tests/test_one.py"
}

suite_model() {  # pass|fail: the model's own, found from scripts/programme/
  local want=1; [[ "$1" == fail ]] && want=2
  : > "$F/scripts/programme/board/__init__.py"
  : > "$F/scripts/programme/board/tests/__init__.py"
  printf 'import unittest\nclass T(unittest.TestCase):\n    def test_one(self):\n        self.assertEqual(1, %s)\n' "$want" \
    > "$F/scripts/programme/board/tests/test_one.py"
}

# check_tests alone, with verify.sh's pass/fail/skip reduced to one line each.
check() {   # [PATH to use]
  run bash -c '
    cd "$1"
    [[ -n "$3" ]] && PATH="$3"
    source <(sed -n "/^check_tests()/,/^}/p" "$2")
    pass() { echo "PASS $2"; }; fail() { echo "FAIL $2"; echo "$3"; }; skip() { echo "SKIP $2"; }
    green() { printf %s "$1"; }; red() { printf %s "$1"; }
    QUICK=0
    check_tests' _ "$F" "$VERIFY" "${1:-}"
}

@test "both runners passing is a pass" {
  check
  assert_line --regexp '^PASS '
}

@test "a failing bats suite fails the check" {
  suite_bats fail
  check
  assert_line --regexp '^FAIL .*bats'
}

@test "a failing Python suite fails the check" {
  suite_python fail
  check
  assert_line --regexp '^FAIL .*unittest'
}

@test "a failing suite of the model's fails the check" {
  suite_model fail
  check
  assert_line --regexp '^FAIL .*unittest:scripts/programme'
}

# The case that let the check hollow out: nothing to run must not read as a pass.
@test "no bats on PATH is a failure, not a skip" {
  local bin="$BATS_TEST_TMPDIR/bin" tool
  mkdir -p "$bin"
  for tool in bash sed grep python3 printf cat; do
    ln -s "$(command -v "$tool")" "$bin/$tool" 2>/dev/null || true
  done
  check "$bin"
  assert_line --regexp '^FAIL bats is not installed'
  refute_line --regexp '^(PASS|SKIP) '
}
