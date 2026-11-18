#!/usr/bin/env bats

# rehearsal-limits.sh, rehearsal-key.sh and seed-rehearsal.sh against rehearsal's
# Turpin layout (#555): the .env is in the state folder, and a change is applied
# with `turpin-host compose`, which refuses where there is no current deploy or
# the lock is held. ssh is stubbed and records what it was asked to run.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  DELIVER="$BATS_TEST_DIRNAME/../deliver"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  export HOME="$BATS_TEST_TMPDIR"
  cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *"turpin-host compose"*) [[ "${COMPOSE_REFUSES:-0}" == 0 ]] || { echo "turpin-host: lock held" >&2; exit 1; } ;;
  *"grep -m1 '^REHEARSAL_ACCESS_KEY='"*) printf 'thekey\n' ;;
  *"ls -1t"*) printf 'turpin-4.tgz\n' ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "$*" >> "$CALLS"\nfor a; do last="$a"; done\n[ -n "${last##*:*}" ] && : > "$last"\nexit 0\n' > "$BIN/scp"
  printf '#!/usr/bin/env bash\necho "{\\"status\\":\\"ok\\"}"\n' > "$BIN/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH"
}

ENVF=/var/lib/turpin/tile-lite-elite/rehearsal/.env

@test "limits regression edits the state folder's .env and applies through turpin-host compose" {
  run "$DELIVER/rehearsal-limits.sh" regression
  assert_success
  assert_equal "$(grep -c "echo 'TILE_LITE_ELITE_LIMIT_REGISTER_PER_MIN=6000' >> $ENVF" "$CALLS")" 1
  assert_equal "$(grep -c 'turpin-host compose tile-lite-elite rehearsal up -d server' "$CALLS")" 1
  assert_equal "$(grep -c 'docker compose' "$CALLS")" 0
  assert_equal "$(grep -c '~/tile-lite-elite' "$CALLS")" 0
}

@test "limits production restores through turpin-host compose" {
  run "$DELIVER/rehearsal-limits.sh" production
  assert_success
  assert_equal "$(grep -c "sed -i '/^TILE_LITE_ELITE_LIMIT_REGISTER_PER_MIN=/d' $ENVF" "$CALLS")" 1
  assert_equal "$(grep -c 'turpin-host compose tile-lite-elite rehearsal up -d server' "$CALLS")" 1
}

@test "limits stops non-zero and says so where turpin-host compose refuses" {
  export COMPOSE_REFUSES=1
  run "$DELIVER/rehearsal-limits.sh" regression
  assert_failure
  assert_output --partial 'could not apply the change'
  refute_output --partial 'rehearsal relaxed'
}

@test "limits show reads the state folder's .env" {
  run "$DELIVER/rehearsal-limits.sh" show
  assert_success
  assert_equal "$(grep -c "grep -E '^TILE_LITE_ELITE_LIMIT_' $ENVF" "$CALLS")" 1
}

@test "key reads the state folder's .env" {
  run "$DELIVER/rehearsal-key.sh"
  assert_success
  assert_output thekey
  assert_equal "$(grep -c "$ENVF" "$CALLS")" 1
}

@test "seed restores, then stops and starts through turpin-host compose" {
  run "$DELIVER/seed-rehearsal.sh"
  assert_success
  assert_output --partial 'Seeded'
  assert_equal "$(grep -c 'turpin-host compose tile-lite-elite rehearsal stop server' "$CALLS")" 1
  assert_equal "$(grep -c 'turpin-host compose tile-lite-elite rehearsal up -d' "$CALLS")" 1
  assert_equal "$(grep -c 'docker compose' "$CALLS")" 0
}

@test "seed restores in the current deploy's server image, through turpin-host compose, and runs no bare docker" {
  run "$DELIVER/seed-rehearsal.sh"
  assert_success
  assert_equal "$(grep -c 'turpin-host compose tile-lite-elite rehearsal run --rm --no-deps' "$CALLS")" 1
  assert_equal "$(grep -c -- '--entrypoint sh' "$CALLS")" 1
  assert_equal "$(grep -c 'tar xzf /snapshots/seeded-' "$CALLS")" 1
  assert_equal "$(grep -c 'docker run' "$CALLS")" 0
  assert_equal "$(grep -c 'tile-lite-elite-server:latest' "$CALLS")" 0
}

@test "seed stops non-zero and says so where turpin-host compose refuses" {
  export COMPOSE_REFUSES=1
  run "$DELIVER/seed-rehearsal.sh"
  assert_failure
  assert_output --partial 'the restore did not complete'
  refute_output --partial 'Seeded'
}
