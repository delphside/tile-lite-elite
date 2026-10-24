#!/usr/bin/env bats

# verify.sh's "Rehearsal is closed" check (#240, #530). It asks rehearsal for
# the sentinel's unlock path and classifies the answer: a keyed host and a
# keyless one both answer 403 and are told apart by the body, and anything the
# gate lets through is open. curl is stubbed, so nothing touches the network.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  VERIFY="$BATS_TEST_DIRNAME/../deliver/verify.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
}

# check CODE BODY: curl answers BODY then CODE as `-w '\n%{http_code}'` would;
# CODE 000 is a curl that failed.
check() {
  export STUB_CODE="$1" STUB_BODY="${2:-}"
  cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
[[ "$STUB_CODE" != 000 ]] || exit 7
printf '%s\n%s' "$STUB_BODY" "$STUB_CODE"
STUB
  chmod +x "$BIN/curl"
  run bash -c '
    PATH="$1:$PATH"
    source <(sed -n "/^check_rehearsal()/,/^}/p" "$2")
    pass() { echo "PASS $2"; }; fail() { echo "FAIL $2"; echo "$3"; }; skip() { echo "SKIP $2"; }
    check_rehearsal
  ' _ "$BIN" "$VERIFY"
}

@test "403 from a keyed host passes" {
  check 403 "Rehearsal is locked. Run ./scripts/rehearsal-access.sh grant and scan the code."
  assert_output --partial 'PASS a key is configured'
}

@test "403 from a keyless host fails, saying it refuses every device" {
  check 403 "Rehearsal has no access key configured. Run ./scripts/deliver/rehearsal-access.sh grant."
  assert_output --regexp '^FAIL '
  assert_output --partial 'refuses every device'
}

@test "200 fails as open" {
  check 200 "<html>the SPA</html>"
  assert_output --regexp '^FAIL '
  assert_output --partial 'OPEN'
}

@test "302 fails as open: the sentinel was honoured" {
  check 302 ""
  assert_output --regexp '^FAIL '
  assert_output --partial 'OPEN'
}

@test "no answer fails as not answering" {
  check 000
  assert_output --regexp '^FAIL '
  assert_output --partial 'did not answer'
}
