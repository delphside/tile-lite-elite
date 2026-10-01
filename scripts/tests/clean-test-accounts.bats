#!/usr/bin/env bats

# clean-test-accounts.sh. The case that matters is the one that reads as
# success: a cleaner pointed at something it cannot reach must be loud and
# non-zero, not "removed 0". That is #128's defect, and the same shape as the
# milestone gate #207 fixed: a check that cannot tell "nothing to do" from
# "not looking".
#
# The admin CLI is reached through a stubbed docker, so nothing real is touched;
# ssh, scp and curl are stubs that record and fail, so a broken guard cannot
# reach a host either.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  CLEAN="$BATS_TEST_DIRNAME/../application/deliver/clean-test-accounts.sh"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  # docker, preview's route: `users list` answers with $LISTING, and
  # `users delete` obeys $DELETE_EXIT.
  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"users list"*)   [[ "${LIST_EXIT:-0}" == 0 ]] || { echo "connection refused" >&2; exit 1; }
                    printf '%s' "${LISTING:-[]}" ;;
  *"users delete"*) echo "$*" >> "$CALLS"; exit "${DELETE_EXIT:-0}" ;;
  *)                : ;;
esac
STUB
  for tool in ssh scp curl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit 1\n' "$tool" > "$BIN/$tool"
  done
  chmod +x "$BIN"/*
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export PATH="$BIN:$PATH"
  export LISTING='[]'
}

clean() { run "$CLEAN" --prefix e2e- "$@"; }
calls() { grep -c "$1" "$CALLS" || true; }

# 1, not 3: D46 and #330. The refusal is the strongest stop this script has; it
# carries on with nothing and deletes nothing, which is `fatal` in the scheme.
# The caller's need to tell "refused because wrong environment" from any other
# failure is met by the message, which D46 put there deliberately.
@test "production is refused, by name and by URL, and nothing is called" {
  clean --target production
  assert_equal "$status" 1
  clean --target https://tileliteelite.com
  assert_equal "$status" 1
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

@test "an unrecognised target is refused rather than guessed" {
  clean --target https://example.invalid
  assert_equal "$status" 1
  assert_equal "$(grep -c . "$CALLS" || true)" 0
}

# The defect this exists to remove.
@test "an unreachable target is loud and non-zero" {
  export LIST_EXIT=1
  clean --target http://localhost:8081
  assert_equal "$status" 1
  assert_output --partial "could not reach"
}

@test "it removes only the matching accounts, and says how many" {
  export LISTING='[{"display_name":"e2e-alice"},{"display_name":"e2e-bob"},{"display_name":"steve"}]'
  clean --target http://localhost:8081
  assert_equal "$(calls 'users delete')" 2
  # `steve` alone matches the repository path in every stubbed argument list,
  # /home/steve/..., so the account is matched as the delete's argument.
  assert_equal "$(calls 'users delete steve$')" 0
  assert_output --partial "removed 2 of 2"
}

@test "nothing to clean, and nothing expected, is success" {
  export LISTING='[{"display_name":"steve"}]'
  clean --target http://localhost:8081
  assert_success
}

@test "but not when the caller says it made some" {
  export LISTING='[{"display_name":"steve"}]'
  clean --target http://localhost:8081 --expect 3
  assert_equal "$status" 1
  assert_output --partial "found none"
}

@test "a refused delete is a failure, not a shrug" {
  export LISTING='[{"display_name":"e2e-alice"}]' DELETE_EXIT=1
  clean --target http://localhost:8081
  assert_equal "$status" 1
}
