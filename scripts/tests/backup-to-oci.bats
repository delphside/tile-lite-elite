#!/usr/bin/env bats

# backup-to-oci.sh, against stubbed docker, curl and sqlite3. It runs
# unattended at 03:00, where a silent abort is the worst kind. What matters is
# the failure paths: the success path announces itself, and the failures would
# otherwise be discovered by a restore that does not work.
#
# HOME is a scratch directory, so no real credential can be found; curl is a
# stub, so nothing reaches a bucket either way.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../application/operate/backup-to-oci.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bin"
  # docker: `cp` produces a file, anything else succeeds.
  cat > "$D/bin/docker" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == cp ]]; then printf 'SQLite format 3\0' > "${@: -1}"; exit 0; fi
done
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
  run env -u PAR_URL PATH="$D/bin:$PATH" HOME="$D" ${1:+PAR_URL="$1"} COMPOSE="$D/compose.yml" bash "$SCRIPT"
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
  for f in backup-to-oci.sh restore-backup.sh check-log-hygiene-nightly.sh; do
    [[ -e "$BATS_TEST_DIRNAME/../$f" ]] || continue
    # Uncommented occurrences only: the explanatory comments quote the flag.
    run bash -c "grep -vE '^[[:space:]]*#' '$BATS_TEST_DIRNAME/../$f' | grep -c -- '-T -'"
    assert_output 0
  done
}
