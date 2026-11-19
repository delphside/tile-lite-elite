# Shared by turpin/tests/*.bats: stubs for `docker`, `curl`, `timeout`, `gh`
# and `cargo` on PATH, and a scratch tree to run a hook in. Each stub logs its
# arguments to a file in the test's own folder and answers from variables the
# test sets, so a hook runs for real against them.
#
# `docker` is the one that does work: its `run` executes the hook's own `tar`
# or `sh -c` against folders on this machine, with `/data` and `/snapshots`
# (the paths inside a container) rewritten to $DATA_DIR and $SNAP_DIR, so a
# snapshot is taken and restored with the commands the hook gives, not a copy of them.
#
#   STUB_CONTAINER     the id `docker ps` prints; empty means no server is running
#   STUB_PS_RC         the status of `docker ps`
#   STUB_SCHEMA_LABEL what `docker image inspect` prints
#   STUB_VOLUME_RC     the status of `docker volume inspect` (1 = no volume)
#   STUB_APPLIED       what the migration query prints (a number, or `none`)
#   STUB_DOCKER_RC     the status of `docker compose` and `docker buildx`
#   STUB_RUN_RC        the status of `docker run`, which fails before it does anything
#   STUB_HEALTH        what `curl` prints; STUB_CURL_RC its status
#   TIMEOUT_EXPIRES    1: every `timeout` expires at once (status 124)
#   TIMEOUT_REAL       seconds a `timeout` really waits, in place of its limit

common_setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  HOOKS="$(cd "$BATS_TEST_DIRNAME/../hooks" && pwd)"
  REAL_TIMEOUT="$(command -v timeout)"
  export REAL_TIMEOUT
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" TIMEOUT_LOG="$BATS_TEST_TMPDIR/timeout.log"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log" GH_LOG="$BATS_TEST_TMPDIR/gh.log" CARGO_LOG="$BATS_TEST_TMPDIR/cargo.log"
  : > "$DOCKER_LOG"; : > "$TIMEOUT_LOG"; : > "$CURL_LOG"; : > "$GH_LOG"; : > "$CARGO_LOG"

  cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  ps) [[ -z "${STUB_CONTAINER:-}" ]] || echo "$STUB_CONTAINER"; exit "${STUB_PS_RC:-0}" ;;
  image) echo "${STUB_SCHEMA_LABEL:-}" ;;
  volume) exit "${STUB_VOLUME_RC:-0}" ;;
  exec) echo "${STUB_APPLIED:-none}" ;;
  stop) ;;
  compose|buildx) exit "${STUB_DOCKER_RC:-0}" ;;
  run)
    [[ -z "${STUB_RUN_RC:-}" ]] || exit "$STUB_RUN_RC"
    shift
    while [[ "$1" != --entrypoint ]]; do shift; done
    entry="$2"; shift 3   # past the entrypoint and the image
    if [[ "$entry" == sh && "$2" == *sqlite3* ]]; then echo "${STUB_APPLIED:-none}"; exit 0; fi
    [[ -n "${DATA_DIR:-}" && -n "${SNAP_DIR:-}" ]] || { echo "stub docker: DATA_DIR and SNAP_DIR are not set" >&2; exit 99; }
    rewrite() { sed -e "s#/snapshots#$SNAP_DIR#g" -e "s#/data#$DATA_DIR#g"; }
    if [[ "$entry" == tar ]]; then
      args=(); for a in "$@"; do args+=("$(printf '%s' "$a" | rewrite)"); done
      exec tar "${args[@]}"
    fi
    exec sh -c "$(printf '%s' "$2" | rewrite)"
    ;;
esac
STUB
  cat > "$STUBS/timeout" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$TIMEOUT_LOG"
[[ -z "${TIMEOUT_EXPIRES:-}" ]] || exit 124
limit="${TIMEOUT_REAL:-$1}"
shift
exec "$REAL_TIMEOUT" "$limit" "$@"
STUB
  cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
printf '%s' "${STUB_HEALTH:-}"
exit "${STUB_CURL_RC:-0}"
STUB
  cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
printf '%s\n' "${STUB_ISSUES:-}"
STUB
  cat > "$STUBS/cargo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CARGO_LOG"
exit "${STUB_CARGO_RC:-0}"
STUB
  chmod +x "$STUBS"/*
  PATH="$STUBS:$PATH"

  # The environment Turpin gives a host hook.
  export TURPIN_APP=tile-lite-elite TURPIN_ENV=rehearsal TURPIN_ROLE=rehearsal
  export TURPIN_SHA=0123456789abcdef0123456789abcdef01234567 TURPIN_VERSION=0.10.2
  export TURPIN_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$TURPIN_STATE"
  # Not every hook is given an image (a rollback's request names none): a test
  # that wants one calls `with_image`.
  unset TURPIN_IMAGE_SERVER TURPIN_DEPLOY_DIR TURPIN_URL TURPIN_COMPOSE TURPIN_DEPLOY TURPIN_CURRENT TURPIN_LOCAL
}

# with_image: the TURPIN_IMAGE_SERVER an apply or a deploy gives its hooks.
with_image() {
  export TURPIN_IMAGE_SERVER=registry.test/tile-lite-elite/candidates@sha256:aaaa
}

# a_data_folder: the volume's contents and the snapshot folder, as folders here.
a_data_folder() {
  export DATA_DIR="$BATS_TEST_TMPDIR/data" SNAP_DIR="$BATS_TEST_TMPDIR/snapshots"
  mkdir -p "$DATA_DIR" "$SNAP_DIR"
  echo "game one" > "$DATA_DIR/tile-lite-elite.sqlite3"
  echo "TLE_SNAPSHOT_DIR=$SNAP_DIR" > "$TURPIN_STATE/.env"
}

# a_tree: a scratch git checkout with the hooks and the migrations, and a script
# `check-release-version.sh` that logs what it was given. EXPORT_HOOKS is the
# hooks as Turpin runs `release-check`: exported to a scratch folder apart from
# the repository, with the repository as the working directory.
a_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/turpin" "$TREE/crates/server-game/migrations" "$TREE/scripts/deliver"
  cp -r "$HOOKS" "$TREE/turpin/hooks"
  EXPORT_HOOKS="$BATS_TEST_TMPDIR/export/turpin/hooks"
  mkdir -p "$BATS_TEST_TMPDIR/export/turpin"
  cp -r "$HOOKS" "$EXPORT_HOOKS"
  git init -q "$TREE"
  touch "$TREE/crates/server-game/migrations/0001_first.sql" \
    "$TREE/crates/server-game/migrations/0007_database_size_history.sql" \
    "$TREE/crates/server-game/migrations/0009_ninth.sql"
  touch "$TREE/docker-compose.yml"
  cat > "$TREE/scripts/deliver/check-release-version.sh" <<'STUB'
#!/usr/bin/env bash
echo "$* strict=${CHECK_RELEASE_STRICT:-}" > "$RELEASE_CHECK_LOG"
exit "${STUB_RELEASE_CHECK_RC:-0}"
STUB
  chmod +x "$TREE/scripts/deliver/check-release-version.sh"
  export RELEASE_CHECK_LOG="$BATS_TEST_TMPDIR/release-check.log"
}
