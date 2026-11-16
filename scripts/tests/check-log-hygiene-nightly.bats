#!/usr/bin/env bats

# check-log-hygiene-nightly.sh, against a stubbed journalctl and curl and a
# temporary Turpin root. A clean run refreshes the marker; a dirty run, or an
# upload that fails, leaves it alone and exits non-zero. It takes no lock.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../operate/check-log-hygiene-nightly.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/turpin/rehearsal"
  printf 'SECRET=hush\nTLE_UPLOAD=local\n' > "$D/turpin/rehearsal/.env"
  export CALLS="$D/calls"; : > "$CALLS"
  # An empty journal is clean; JOURNAL carries a line for the validator.
  printf '#!/usr/bin/env bash\nprintf "%%s" "${JOURNAL:-}"\n' > "$D/bin/journalctl"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "$CALLS"\n' > "$D/bin/curl"
  printf '#!/usr/bin/env bash\necho "flock $*" >> "$CALLS"\n' > "$D/bin/flock"
  chmod +x "$D/bin/"*
}

nightly() {
  run env -u PAR_URL PATH="$D/bin:$PATH" HOME="$D" EXCEPTIONS="$D/exceptions" \
    TLE_TURPIN_ROOT="$D/turpin" bash "$SCRIPT"
}

@test "local: a clean run writes the marker into uploads/ and takes no lock" {
  nightly
  assert_success
  [[ -s "$D/turpin/rehearsal/uploads/marker-logcheck-ok" ]]
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

@test "par: a clean run PUTs the marker from a file" {
  echo TLE_UPLOAD=par > "$D/turpin/rehearsal/.env"
  echo https://example.invalid/p/x/o/ > "$D/.tile-lite-elite-backup-par"
  nightly
  assert_success
  grep -q -- "--max-time 60 -T .* https://example.invalid/p/x/o/marker-logcheck-ok" "$CALLS"
}

@test "local-fail: the marker is not written and the run fails" {
  echo TLE_UPLOAD=local-fail > "$D/turpin/rehearsal/.env"
  nightly
  assert_failure
  [[ ! -e "$D/turpin/rehearsal/uploads" ]]
}

@test "a dirty log fails and leaves the marker alone" {
  mkdir "$D/turpin/rehearsal/uploads"
  echo old > "$D/turpin/rehearsal/uploads/marker-logcheck-ok"
  JOURNAL='{"event":"x","who":"a@b.com"}' nightly
  assert_failure
  assert_equal "$(cat "$D/turpin/rehearsal/uploads/marker-logcheck-ok")" old
  grep -q EXCEPTIONS "$D/exceptions"
}

@test "an unknown or unset TLE_UPLOAD is refused, naming the key" {
  echo TLE_UPLOAD=ftp > "$D/turpin/rehearsal/.env"
  nightly
  assert_failure
  assert_output --partial "TLE_UPLOAD"
  echo OTHER=1 > "$D/turpin/rehearsal/.env"
  nightly
  assert_failure
  assert_output --partial "TLE_UPLOAD"
}

@test "zero or two .env files are refused" {
  rm "$D/turpin/rehearsal/.env"
  nightly
  assert_failure
  assert_output --partial "exactly one"
  mkdir "$D/turpin/b" "$D/turpin/c"
  echo TLE_UPLOAD=local > "$D/turpin/b/.env"; echo TLE_UPLOAD=local > "$D/turpin/c/.env"
  nightly
  assert_failure
  assert_output --partial "exactly one"
}
