#!/usr/bin/env bats

# backup-to-oci.sh, against stubbed docker, curl and sqlite3, and a temporary
# Turpin root holding one environment's state folder. It runs unattended at
# 03:00, where a silent abort is the worst kind. What matters is the failure
# paths: the success path announces itself, and the failures would otherwise be
# discovered by a restore that does not work.
#
# HOME is a scratch directory, so no real credential can be found; curl is a
# stub, so nothing reaches a bucket either way. The upload function itself is
# tested in upload.bats.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../operate/backup-to-oci.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin" "$D/turpin/rehearsal"
  printf 'OTHER=secret\nTLE_UPLOAD=par\n' > "$D/turpin/rehearsal/.env"
  export CALLS="$D/calls"; : > "$CALLS"
  # docker: `ps` answers with $PS_OUT (one container by default), `cp`
  # produces a file, anything else succeeds. Every call is recorded.
  cat > "$D/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
if [[ "$1" == ps ]]; then printf '%b' "${PS_OUT-abc123\n}"; exit 0; fi
if [[ "$1" == cp ]]; then printf 'SQLite format 3\0' > "${@: -1}"; exit 0; fi
exit 0
STUB
  chmod +x "$D/bin/docker"
}

tools() {   # <integrity> <upload-exit> <marker-exit>
  printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$D/bin/sqlite3"
  printf '#!/usr/bin/env bash\nif [[ "$*" == *marker-backup-ok* ]]; then exit %s; fi\nexit %s\n' "$3" "$2" > "$D/bin/curl"
  chmod +x "$D/bin/sqlite3" "$D/bin/curl"
}

backup() {  # [PAR_URL]
  # -u: a PAR_URL in the caller's own environment must never reach a case.
  run env -u PAR_URL PATH="$D/bin:$PATH" HOME="$D" ${1:+PAR_URL="$1"} \
    TLE_TURPIN_ROOT="$D/turpin" TLE_LOCK_WAIT=1 bash "$SCRIPT"
}

@test "a good backup uploads and marks" {
  tools ok 0 0
  backup "https://example.invalid/p/x/o/"
  assert_success
  assert_output --partial uploaded
}

@test "a corrupt copy is never uploaded" {
  tools "*** in database main" 0 0
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "integrity check failed"
}

@test "a failed upload is an error" {
  tools ok 1 0
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "upload failed"
}

@test "a failed marker warns but does not fail" {
  tools ok 0 1
  backup "https://example.invalid/p/x/o/"
  assert_success
  assert_output --partial "the alarm will fire"
}

# The one that would otherwise upload nothing, quietly.
@test "no credential is an error, not a silent no-op" {
  tools ok 0 0
  backup
  assert_failure
  assert_output --partial "no PAR_URL"
}

# The one thing a stubbed curl can never check. Every case above answers
# through a fake curl, which accepts any arguments. That let a real defect pass
# a green suite on 2026-08-23: all three marker uploads used `curl -T -`,
# reading the body from stdin, so curl sent `Transfer-Encoding: chunked` and
# OCI Object Storage answered 501 Not Implemented (measured on the production
# host: stdin 501, the same bytes from a file 200). The alarms watch marker
# objects for absence of success, so none could ever have been satisfied. What
# can be checked is the flag, in every script that uploads.
@test "no script uploads a marker from stdin" {
  local f
  for f in backup-to-oci.sh restore-backup.sh check-log-hygiene-nightly.sh upload.sh; do
    [[ -e "$BATS_TEST_DIRNAME/../operate/$f" ]] || fail "$f is not where this test looks"
    # Uncommented occurrences only: the explanatory comments quote the flag.
    run bash -c "grep -vE '^[[:space:]]*#' '$BATS_TEST_DIRNAME/../operate/$f' | grep -c -- '-T -'"
    assert_output 0
  done
}

# --- the environment, the server and the lock ---------------------------------

@test "no .env, or two, is refused before anything runs" {
  tools ok 0 0
  rm "$D/turpin/rehearsal/.env"
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "exactly one"
  mkdir "$D/turpin/a" "$D/turpin/b"
  echo TLE_UPLOAD=local > "$D/turpin/a/.env"; echo TLE_UPLOAD=local > "$D/turpin/b/.env"
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "exactly one"
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

@test "an unknown or unset TLE_UPLOAD is refused, naming the key" {
  tools ok 0 0
  echo 'TLE_UPLOAD=ftp' > "$D/turpin/rehearsal/.env"
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "TLE_UPLOAD"
  echo 'OTHER=1' > "$D/turpin/rehearsal/.env"
  backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "TLE_UPLOAD"
}

@test "the server is found by its Compose labels and reached by exec and cp" {
  tools ok 0 0
  backup "https://example.invalid/p/x/o/"
  assert_success
  grep -q "docker ps -q --filter label=com.docker.compose.project=tile-lite-elite --filter label=com.docker.compose.service=server --filter status=running" "$CALLS"
  grep -q "docker exec abc123 sqlite3" "$CALLS"
  grep -q "docker cp abc123:/data/backup-" "$CALLS"
  run grep -c "compose " "$CALLS"
  assert_output 0
}

@test "no server container, or two, is refused" {
  tools ok 0 0
  PS_OUT='' backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "found 0"
  PS_OUT='a\nb\n' backup "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "found 2"
  run grep -c "docker exec" "$CALLS"
  assert_output 0
}

@test "a held lock refuses after the wait and nothing runs" {
  tools ok 0 0
  flock "$D/turpin/rehearsal/lock" sleep 5 &
  local holder=$!
  sleep 0.5
  backup "https://example.invalid/p/x/o/"
  kill "$holder" 2>/dev/null || true
  assert_failure 75
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

@test "the lock is free again after a backup" {
  tools ok 0 0
  backup "https://example.invalid/p/x/o/"
  assert_success
  run flock -n "$D/turpin/rehearsal/lock" true
  assert_success
}

@test "local-fail fails the backup; local keeps one database copy and a marker" {
  tools ok 0 0
  echo 'TLE_UPLOAD=local-fail' > "$D/turpin/rehearsal/.env"
  backup
  assert_equal "$status" 1
  assert_output --partial "upload failed"
  [[ ! -e "$D/turpin/rehearsal/uploads" ]]
  echo 'TLE_UPLOAD=local' > "$D/turpin/rehearsal/.env"
  backup
  assert_success
  run bash -c "ls '$D'/turpin/rehearsal/uploads/db-*.sqlite3.gz | wc -l"
  assert_output 1
  [[ -e "$D/turpin/rehearsal/uploads/marker-backup-ok" ]]
}
