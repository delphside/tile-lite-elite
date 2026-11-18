#!/usr/bin/env bats

# upload.sh, the one upload function the backup and the log check share. The
# adapter is chosen by TLE_UPLOAD in the one Turpin .env. Only the HTTP PUT
# through the PAR goes untested before production, and curl is a stub here.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  UPLOAD="$BATS_TEST_DIRNAME/../operate/upload.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/turpin/rehearsal"
  export CALLS="$D/calls"; : > "$CALLS"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "$CALLS"\nexit "${CURL_EXIT:-0}"\n' > "$D/bin/curl"
  chmod +x "$D/bin/curl"
  echo payload > "$D/obj"
}

env_is() { printf 'SECRET=hush\n%s\n' "$1" > "$D/turpin/rehearsal/.env"; }

# upload NAME: init, then send $D/obj as NAME.
upload() {
  run env -u PAR_URL PATH="$D/bin:$PATH" HOME="$D" ${PAR:+PAR_URL="$PAR"} TLE_TURPIN_ROOT="$D/turpin" \
    bash -c ". '$UPLOAD'; tle_upload_init && tle_upload '$D/obj' '$1'"
}

@test "par: a PUT from a file through the PAR" {
  env_is TLE_UPLOAD=par
  PAR=https://example.invalid/p/x/o/ upload db-1.sqlite3.gz
  assert_success
  grep -q -- "--fail .*--max-time 300 -T $D/obj https://example.invalid/p/x/o/db-1.sqlite3.gz" "$CALLS"
}

@test "par: the PAR is read from the 0600 file when PAR_URL is unset" {
  env_is TLE_UPLOAD=par
  echo https://example.invalid/p/y/o/ > "$D/.tile-lite-elite-backup-par"
  upload marker-x
  assert_success
  grep -q "https://example.invalid/p/y/o/marker-x" "$CALLS"
}

@test "par: no PAR is refused, and a failed PUT fails" {
  env_is TLE_UPLOAD=par
  upload marker-x
  assert_failure
  assert_output --partial "no PAR_URL"
  CURL_EXIT=22 PAR=https://example.invalid/p/x/o/ upload marker-x
  assert_failure
}

@test "local: writes into uploads/ and removes the older database copy" {
  env_is TLE_UPLOAD=local
  mkdir "$D/turpin/rehearsal/uploads"
  echo old > "$D/turpin/rehearsal/uploads/db-0.sqlite3.gz"
  echo keep > "$D/turpin/rehearsal/uploads/marker-backup-ok"
  upload db-1.sqlite3.gz
  assert_success
  [[ ! -e "$D/turpin/rehearsal/uploads/db-0.sqlite3.gz" ]]
  assert_equal "$(cat "$D/turpin/rehearsal/uploads/db-1.sqlite3.gz")" payload
  upload marker-backup-ok
  assert_success
  [[ -e "$D/turpin/rehearsal/uploads/db-1.sqlite3.gz" ]]
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

@test "local-fail: fails and writes nothing" {
  env_is TLE_UPLOAD=local-fail
  upload db-1.sqlite3.gz
  assert_failure
  [[ ! -e "$D/turpin/rehearsal/uploads" ]]
}

@test "an unknown or unset TLE_UPLOAD is refused, naming the key" {
  env_is TLE_UPLOAD=ftp
  upload x
  assert_failure
  assert_output --partial "TLE_UPLOAD"
  env_is OTHER=1
  upload x
  assert_failure
  assert_output --partial "TLE_UPLOAD"
}

@test "zero or two .env files are refused" {
  rm -f "$D/turpin/rehearsal/.env"
  upload x
  assert_failure
  assert_output --partial "found 0"
  mkdir "$D/turpin/other"
  echo TLE_UPLOAD=local > "$D/turpin/rehearsal/.env"; echo TLE_UPLOAD=local > "$D/turpin/other/.env"
  upload x
  assert_failure
  assert_output --partial "found 2"
}

@test "the .env is read as text, never sourced" {
  env_is TLE_UPLOAD=local
  echo "touch $D/sourced" >> "$D/turpin/rehearsal/.env"
  upload x
  assert_success
  [[ ! -e "$D/sourced" ]]
}
