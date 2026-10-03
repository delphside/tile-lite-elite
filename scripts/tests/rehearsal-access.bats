#!/usr/bin/env bats

# rehearsal-access.sh. ssh is stubbed, so nothing touches the rehearsal host:
# every case runs against a scripted remote whose .env contents and command
# results are set per test. The cases that matter are the two that would
# otherwise read as success: a host with no key configured, and a key written
# to .env but never applied. The second looks exactly like a wrong key when a
# device is refused.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  ACCESS="$BATS_TEST_DIRNAME/../rehearsal-access.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # The stub answers the three remote reads the script makes, and records the
  # writes so a test can assert what would have happened on the host.
  cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
CMD="$*"
echo "$CMD" >> "$CALLS"
case "$CMD" in
  *"grep -m1 '^REHEARSAL_ACCESS_KEY='"*) printf '%s' "${ENV_KEY:-}" ;;
  *"printenv REHEARSAL_ACCESS_KEY"*)     printf '%s' "${LIVE_KEY:-}" ;;
  *"openssl rand -hex 24"*)              printf '%s' "${NEW_KEY:-deadbeef}" ;;
  *"docker compose up -d web"*)          [[ "${APPLY_EXIT:-0}" == 0 ]] || exit 1
                                         echo applied ;;
  *) : ;;
esac
STUB
  # qrencode prints the code if installed; the URL is printed either way.
  printf '#!/usr/bin/env bash\necho "(qr code)"\n' > "$BIN/qrencode"
  chmod +x "$BIN/ssh" "$BIN/qrencode"
  export PATH="$BIN:$PATH"
  # The ssh key path is derived from $HOME, and never read.
  export HOME="$BATS_TEST_TMPDIR"
}

writes() { grep -c "echo 'REHEARSAL_ACCESS_KEY=$1" "$CALLS" || true; }

@test "no argument, or an unknown one, prints usage and exits 2" {
  run "$ACCESS"
  assert_equal "$status" 2
  run "$ACCESS" unlock-everything
  assert_equal "$status" 2
}

@test "grant on an unconfigured host generates a key, writes it, applies it, and shows it" {
  export ENV_KEY="" NEW_KEY="abc123"
  run "$ACCESS" grant
  assert_output --partial 'No key configured'
  assert_equal "$(writes abc123)" 1
  # Applied with 'up -d web', not restart.
  assert_equal "$(grep -c 'docker compose up -d web' "$CALLS")" 1
  assert_output --partial 'https://rehearsal.tileliteelite.com/unlock/abc123'
}

@test "the sentinel is replaced rather than handed out" {
  export ENV_KEY="no-rehearsal-key-configured" NEW_KEY="fresh99"
  run "$ACCESS" grant
  refute_output --partial 'unlock/no-rehearsal-key-configured'
  assert_output --partial 'unlock/fresh99'
}

# Matched as the write: `REHEARSAL_ACCESS_KEY=` also appears in the read
# command, so the bare string matches a call that changed nothing.
@test "grant on a configured host reuses the key and writes nothing" {
  export ENV_KEY="existing42"
  run "$ACCESS" grant
  assert_output --partial 'unlock/existing42'
  assert_equal "$(writes)" 0
}

@test "revoke writes a new key even when one is set" {
  export ENV_KEY="existing42" NEW_KEY="rotated7"
  run "$ACCESS" revoke
  assert_equal "$(writes rotated7)" 1
}

@test "grant fails when the container will not take the key" {
  export ENV_KEY="" NEW_KEY="abc123" APPLY_EXIT=1
  run "$ACCESS" grant
  assert_equal "$status" 1
}

@test "status: no key in .env reports locked" {
  export ENV_KEY="" LIVE_KEY="no-rehearsal-key-configured"
  run "$ACCESS" status
  assert_output --partial 'locked to everybody'
}

@test "status: a matching pair reports healthy" {
  export ENV_KEY="k1" LIVE_KEY="k1"
  run "$ACCESS" status
  assert_success
}

@test "status: a key written but never applied is non-zero, and says why" {
  export ENV_KEY="k2" LIVE_KEY="k1"
  run "$ACCESS" status
  assert_equal "$status" 1
  assert_output --partial "without 'docker compose up -d web'"
}
