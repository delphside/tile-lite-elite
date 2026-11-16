# What Tile Lite Elite's Turpin hooks share. Sourced by each hook, never run:
# it is not executable, and Turpin finds a hook by name (design 545 §2.2).
#
# A hook answers with its exit status: 0 passed, 75 not yet, anything else
# refused (Turpin's design §8). `die` is the refusal: a message on standard
# error, exit 1. A hook that cannot judge refuses.

HOOK="${BASH_SOURCE[1]##*/}"

die() {
  printf '%s: %s\n' "$HOOK" "$*" >&2
  exit 1
}

# need NAME...: each is set and not empty, or the hook refuses.
need() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "$name is not set, so it cannot judge"
  done
}

# bounded SECONDS COMMAND...: runs the command within the limit (design 545 §3,
# *Limits and timeouts*). Past it, the hook refuses; any other status is the
# command's own, for the caller to judge.
bounded() {
  local limit="$1" rc=0
  shift
  timeout "$limit" "$@" || rc=$?
  if ((rc == 124)); then
    die "did not finish within ${limit}s: $*"
  fi
  return "$rc"
}

# bounded_poll SECONDS FUNCTION: calls the function every 2 seconds until it
# passes, within the limit. Returns 124 past it.
bounded_poll() {
  local limit="$1" fn="$2" rc=0
  export -f "$fn"
  timeout "$limit" bash -c 'until "$0"; do sleep 2; done' "$fn" || rc=$?
  return "$rc"
}

# The Compose project and the data volume of the environment this hook runs in.
# Both are the compose files' own names: docker-compose.yml pins the project
# and the volume, docker-compose.preview.yml has its own.
tle_project() {
  if [[ "${TURPIN_ROLE:-}" == preview ]]; then echo tile-lite-elite-preview; else echo tile-lite-elite; fi
}
tle_volume() {
  if [[ "${TURPIN_ROLE:-}" == preview ]]; then echo tile-lite-elite-preview-data; else echo tile-lite-elite-data; fi
}

# server_containers SECONDS: the ids of the running server containers, found by
# their Compose labels.
server_containers() {
  bounded "$1" docker ps -q \
    --filter "label=com.docker.compose.project=$(tle_project)" \
    --filter "label=com.docker.compose.service=server"
}

# env_value NAME: the value of NAME in the environment's `.env`, which is in
# the state folder (Turpin's design §11); empty where there is none.
env_value() {
  need TURPIN_STATE
  local file="$TURPIN_STATE/.env" line
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^$1=" "$file" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%[\"\']}"
  line="${line#[\"\']}"
  printf '%s' "$line"
}

# snapshot_dir: the folder the snapshots are in, `TLE_SNAPSHOT_DIR`, an absolute
# path. Refuses where it is not set: a hook has nowhere to write or read.
snapshot_dir() {
  local dir
  dir="$(env_value TLE_SNAPSHOT_DIR)"
  [[ -n "$dir" ]] || die "TLE_SNAPSHOT_DIR is not set in $TURPIN_STATE/.env, so there is nowhere to keep a snapshot"
  [[ "$dir" == /* ]] || die "TLE_SNAPSHOT_DIR in $TURPIN_STATE/.env is '$dir', which is not an absolute path"
  printf '%s' "$dir"
}

# app_version_of: reads /health's JSON on standard input, prints its app_version.
app_version_of() {
  grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true
}

# version_ok APP_VERSION: it is `TURPIN_VERSION+` and then a prefix of TURPIN_SHA.
version_ok() {
  local want="$TURPIN_VERSION+" got="$1" id
  [[ "$got" == "$want"* ]] || return 1
  id="${got#"$want"}"
  [[ -n "$id" && "$TURPIN_SHA" == "$id"* ]]
}
export -f app_version_of version_ok
