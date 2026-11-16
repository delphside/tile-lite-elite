#!/usr/bin/env bats

# verify.sh's `deploys` and `gates` checks, and the hooks' tests in `tests`
# (#545, #555). Turpin is a stub that prints what `turpin status ENV` prints
# (programme/scripts/deliver/turpinlib/commands/status.py) and records its
# arguments, so nothing touches a host.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  VERIFY="$BATS_TEST_DIRNAME/../deliver/verify.sh"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export TURPIN="$BATS_TEST_TMPDIR/turpin"
  cat > "$TURPIN" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
if [[ "$1" == release ]]; then
  [[ "${RELEASE_EXIT:-0}" == 0 ]] || echo "turpin: the milestone is unconfirmed" >&2
  exit "${RELEASE_EXIT:-0}"
fi
env="$2"
[[ "${STATUS_EXIT:-0}" == 0 ]] || { echo "turpin: host unreachable" >&2; exit "$STATUS_EXIT"; }
[[ "${CURRENT_NONE:-}" != "$env" ]] || { printf 'environment: %s\nstate: none\ncurrent: none\n' "$env"; exit 0; }
echo "environment: $env"
echo "state: deployed"
echo "current: deploy 3 commit abc version 0.10.2 record 0.10.2 smoke passed t"
echo "image server sha256:aa"
if [[ "${IMAGE_DIFFERS:-}" == "$env" ]]; then echo "running: DIFFERS from the current digests (sha256:bb)"
else echo "running: the current digests"; fi
if [[ "${NO_RECORD:-}" == "$env" ]]; then echo "record: none matches"; else echo "record: 0.10.2"; fi
echo "host file /opt/tile-lite-elite/backup-to-oci.sh: equal"
if [[ "${FILE_DIFFERS:-}" == "$env" ]]; then echo "host file /etc/systemd/system/tle-backup.service: differs"
else echo "host file /etc/systemd/system/tle-backup.service: equal"; fi
STUB
  chmod +x "$TURPIN"
}

# One check function, alone, with the verdict helpers reduced to a line each.
check() {   # FUNCTION
  run bash -c '
    cd "$BATS_TEST_TMPDIR"
    source <(sed -n "/^$2()/,/^}/p" "$1")
    pass() { echo "PASS $2"; }; fail() { echo "FAIL $2"; echo "$3"; }; skip() { echo "SKIP $2"; }
    green() { printf %s "$1"; }; red() { printf %s "$1"; }
    QUICK=0
    $2' _ "$VERIFY" "$1"
}

@test "deploys asks status of rehearsal and of production, and passes where they match" {
  check check_deploys
  assert_line --regexp '^PASS '
  assert_equal "$(grep -c '^status rehearsal$' "$CALLS")" 1
  assert_equal "$(grep -c '^status production$' "$CALLS")" 1
}

@test "deploys is red where a host file differs" {
  export FILE_DIFFERS=production
  check check_deploys
  assert_line --regexp '^FAIL .*production'
  assert_output --partial 'tle-backup.service: differs'
  refute_line --regexp '^PASS '
}

@test "deploys is red where the containers run another image" {
  export IMAGE_DIFFERS=rehearsal
  check check_deploys
  assert_line --regexp '^FAIL .*rehearsal'
  assert_output --partial 'running: DIFFERS'
}

@test "deploys is red where no record matches" {
  export NO_RECORD=production
  check check_deploys
  assert_line --regexp '^FAIL '
  assert_output --partial 'record: none matches'
}

@test "deploys is red where there is no current deploy" {
  export CURRENT_NONE=rehearsal
  check check_deploys
  assert_line --regexp '^FAIL '
  assert_output --partial 'no current turpin deploy'
}

@test "deploys is red where status cannot be read" {
  export STATUS_EXIT=75
  check check_deploys
  assert_line --regexp '^FAIL '
  assert_output --partial 'could not be read'
}

@test "gates runs turpin release --check, and passes where it does" {
  check check_gates
  assert_line --regexp '^PASS '
  assert_equal "$(grep -c '^release --check$' "$CALLS")" 1
}

@test "gates fails where turpin release --check refuses, with its reason" {
  export RELEASE_EXIT=1
  check check_gates
  assert_line --regexp '^FAIL '
  assert_output --partial 'the milestone is unconfirmed'
}

@test "gates does not call deploy.sh" {
  run grep -c 'DEPLOY_GATES_ONLY' "$VERIFY"
  assert_output 0
}

# --- tests also runs the hooks' Bats tests ------------------------------------

tests_in() {   # a fixture repo
  run bash -c '
    cd "$1"
    source <(sed -n "/^check_tests()/,/^}/p" "$2")
    pass() { echo "PASS $2"; }; fail() { echo "FAIL $2"; echo "$3"; }; skip() { echo "SKIP $2"; }
    green() { printf %s "$1"; }; red() { printf %s "$1"; }
    QUICK=0
    check_tests' _ "$1" "$VERIFY"
}

fixture() {   # a repo with one passing suite of each kind
  F="$BATS_TEST_TMPDIR/repo"; mkdir -p "$F/scripts/tests"
  printf '#!/usr/bin/env bats\n@test "one" {\n  [ 1 = 1 ]\n}\n' > "$F/scripts/tests/one.bats"
  : > "$F/scripts/tests/__init__.py"
  printf 'import unittest\nclass T(unittest.TestCase):\n    def test_one(self):\n        self.assertEqual(1, 1)\n' > "$F/scripts/tests/test_one.py"
}

@test "tests runs turpin/tests where it exists, and a failing hook test fails the check" {
  fixture
  mkdir -p "$F/turpin/tests"
  printf '#!/usr/bin/env bats\n@test "hook" {\n  [ 1 = 2 ]\n}\n' > "$F/turpin/tests/hook.bats"
  tests_in "$F"
  assert_line --regexp '^FAIL .*bats:turpin/tests'
}

@test "tests passes with a passing turpin/tests" {
  fixture
  mkdir -p "$F/turpin/tests"
  printf '#!/usr/bin/env bats\n@test "hook" {\n  [ 1 = 1 ]\n}\n' > "$F/turpin/tests/hook.bats"
  tests_in "$F"
  assert_output --partial 'bats turpin/tests: 1 tests'
  assert_line --regexp '^PASS '
}

@test "tests says nothing about turpin/tests where the folder is absent" {
  fixture
  tests_in "$F"
  refute_output --partial 'turpin/tests'
  assert_line --regexp '^PASS '
}
