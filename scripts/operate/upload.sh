# Sourced by backup-to-oci.sh and check-log-hygiene-nightly.sh: the one place
# that decides where an object goes. Installed beside them in
# /opt/tile-lite-elite/.
#
# `TLE_UPLOAD`, read from the environment's Turpin `.env`, chooses the adapter:
#   par         HTTP PUT through the write-only PAR (production)
#   local       a copy in `uploads/` in the state folder (rehearsal)
#   local-fail  reports failure and writes nothing (tests)
# Anything else, or unset, is refused.
#
# The `.env` holds secrets and other keys, so one key is read as text and the
# file is never sourced.

TLE_TURPIN_ROOT="${TLE_TURPIN_ROOT:-/var/lib/turpin/tile-lite-elite}"

# Sets STATE_DIR to the one environment's state folder, or refuses.
tle_find_state() {
  local found=("$TLE_TURPIN_ROOT"/*/.env) n=0 f
  for f in "${found[@]}"; do [[ -f "$f" ]] && n=$((n + 1)); done
  if [[ $n -ne 1 ]]; then
    echo "error: expected exactly one $TLE_TURPIN_ROOT/*/.env, found $n" >&2
    return 1
  fi
  STATE_DIR="$(dirname "${found[0]}")"
}

# Prints the value of one key in the state folder's .env; empty where absent.
tle_setting() {
  local line
  line="$(grep -E "^$1=" "$STATE_DIR/.env" | tail -n1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

# Finds the state folder, reads TLE_UPLOAD and checks the adapter can work.
# The PAR is read from a 0600 file, never from the unit: `systemctl show` is
# world readable and a PAR URL is a bearer token.
tle_upload_init() {
  tle_find_state || return 1
  TLE_UPLOAD="$(tle_setting TLE_UPLOAD)"
  case "$TLE_UPLOAD" in
    par)
      PAR_URL="${PAR_URL:-}"
      if [[ -z "$PAR_URL" && -r "$HOME/.tile-lite-elite-backup-par" ]]; then
        PAR_URL="$(< "$HOME/.tile-lite-elite-backup-par")"
      fi
      [[ -n "$PAR_URL" ]] || { echo "error: no PAR_URL, and no ~/.tile-lite-elite-backup-par" >&2; return 1; } ;;
    local|local-fail) ;;
    *) echo "error: TLE_UPLOAD in $STATE_DIR/.env is '$TLE_UPLOAD'; expected par, local or local-fail" >&2
       return 1 ;;
  esac
}

# tle_upload FILE NAME [SECONDS]: send FILE as the object NAME; non-zero on failure.
# From a file, never stdin: `curl -T -` sends chunked, which OCI answers with 501.
tle_upload() {
  local file="$1" name="$2" max="${3:-300}"
  case "$TLE_UPLOAD" in
    par)
      curl --fail --silent --show-error --max-time "$max" -T "$file" "${PAR_URL}${name}" ;;
    local)
      mkdir -p "$STATE_DIR/uploads"
      # One database copy is kept: the older one goes before the new one lands.
      if [[ "$name" == db-*.sqlite3.gz ]]; then rm -f "$STATE_DIR"/uploads/db-*.sqlite3.gz; fi
      cp "$file" "$STATE_DIR/uploads/$name.part" && mv "$STATE_DIR/uploads/$name.part" "$STATE_DIR/uploads/$name" ;;
    local-fail)
      echo "local-fail: not writing $name" >&2
      return 1 ;;
    *) echo "error: tle_upload_init was not run" >&2; return 1 ;;
  esac
}
