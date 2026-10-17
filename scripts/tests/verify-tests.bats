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
  VERIFY="$BATS_TEST_DIRNAME/../deliver/verify.sh"
  F="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$F/scripts/tests"
  suite_bats pass
  suite_python pass
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

# The board model's suite is the programme's, run by its own CI (#485), so this check
# does not look for one: a `programme/` folder in the fixture proves it is not run.
@test "the programme's suites are not this check's: a failing one there does not fail it" {
  mkdir -p "$F/programme/scripts/board/tests"
  : > "$F/programme/scripts/board/__init__.py"
  : > "$F/programme/scripts/board/tests/__init__.py"
  printf 'import unittest\nclass T(unittest.TestCase):\n    def test_one(self):\n        self.assertEqual(1, 2)\n' \
    > "$F/programme/scripts/board/tests/test_one.py"
  check
  assert_line --regexp '^PASS '
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

# --- check_unreleased asks `ships` through shipping-paths.sh -------------------------
# It once called board-shipping.py itself and stopped only on 70, so Python's 2 for
# a programme/ that was not there read as "does not ship": production level with main.

unreleased() {   # <command for the shipping rule>
  local repo="$BATS_TEST_TMPDIR/rel"
  rm -rf "$repo"; mkdir -p "$repo"; git init -q "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m base
  PROD_SHA="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" commit -q --allow-empty -m "an image change"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/bin/sh\nprintf %%s %s\n' "'{\"app_version\":\"0.0.1+$PROD_SHA\"}'" > "$bin/curl"; chmod +x "$bin/curl"
  run env PATH="$bin:$PATH" bash -c '
    cd "$1"
    source "$3/scripts/deliver/shipping-paths.sh"
    _SHIPPING_CMD="$4"
    source <(sed -n "/^check_unreleased()/,/^}/p" "$2")
    pass() { echo "PASS $2"; }; note() { echo "NOTE $2"; }; fail() { echo "FAIL $2"; }
    check_unreleased; echo "carried-on"' _ "$repo" "$VERIFY" "$BATS_TEST_DIRNAME/../.." "$1"
}

@test "unreleased: a shipping rule that says yes is counted" {
  printf 'import sys\nsys.exit(0)\n' > "$BATS_TEST_TMPDIR/yes.py"
  unreleased "$BATS_TEST_TMPDIR/yes.py"
  assert_output --partial "NOTE 1 image change(s) on main"
}

@test "unreleased: a shipping rule that says no is level with production" {
  printf 'import sys\nsys.exit(1)\n' > "$BATS_TEST_TMPDIR/no.py"
  unreleased "$BATS_TEST_TMPDIR/no.py"
  assert_output --partial "PASS production is level"
}

@test "unreleased: a missing shipping script stops verify, and is not read as no" {
  unreleased "$BATS_TEST_TMPDIR/no-such/board-shipping.py"
  assert_equal "$status" 70
  refute_output --partial "PASS production is level"
  refute_output --partial "carried-on"
  assert_output --partial "git submodule update --init"
}
