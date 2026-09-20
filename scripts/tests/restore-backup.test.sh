#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/restore-backup.sh under its real `set -euo pipefail`, against a
# stubbed `curl` serving a real gzipped SQLite file.
#
# The cases that matter are the ones where it must **refuse**. A restore that
# quietly proceeds with a bad file is worse than one that fails, because the
# failure is discovered later and by then the good copy may be gone.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/restore-backup.sh"
failures=0
command -v sqlite3 >/dev/null || { echo "skip: no sqlite3 on this machine"; exit 0; }

# Builds a bucket: a listing, and one object which is a real database.
make_bucket() {   # $1 = dir, $2 = players to insert
  local dir="$1" n="$2"
  mkdir -p "$dir/bucket" "$dir/bin"
  sqlite3 "$dir/db.sqlite3" \
    "create table players(id text); create table games(id text);" >/dev/null
  for ((i = 0; i < n; i++)); do
    sqlite3 "$dir/db.sqlite3" "insert into players values ('p$i');" >/dev/null
  done
  gzip -c "$dir/db.sqlite3" > "$dir/bucket/db-20260821T030000Z.sqlite3.gz"
  cat > "$dir/bucket/list.json" <<'JSON'
{"objects":[{"name":"db-20260820T030000Z.sqlite3.gz"},{"name":"db-20260821T030000Z.sqlite3.gz"}]}
JSON
  cat > "$dir/bin/curl" <<STUB
#!/usr/bin/env bash
url="\${@: -1}"
case "\$url" in
  */o/)       cat "$dir/bucket/list.json" ;;
  *db-20260821*) cat "$dir/bucket/db-20260821T030000Z.sqlite3.gz" ;;
  *)          exit 22 ;;
esac
STUB
  chmod +x "$dir/bin/curl"
}

run() {   # $1 name, $2 players, $3 want-exit, $4 want-text
  local dir; dir="$(mktemp -d)"
  make_bucket "$dir" "$2"
  local out status
  set +e
  out="$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$SCRIPT" "https://example.invalid/p/x/o/" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne "$3" ]]; then
    echo "FAIL  $1: exit $status, wanted $3"; echo "      $out"; failures=1
  elif [[ -n "$4" && "$out" != *"$4"* ]]; then
    echo "FAIL  $1: did not mention '$4'"; echo "      $out"; failures=1
  else
    echo "ok    $1"
  fi
  rm -rf "$dir"
}

# --- the volume is in use ---------------------------------------------------- #385
#
# **The case with no error to catch.** Replacing the database under a live
# connection succeeds -- POSIX keeps the unlinked inode alive -- so nothing
# fails until the next restart, by which time the good copy may be gone. The
# refusal is the only thing standing between those two moments.
volume_case() {   # $1 name, $2 holders printed by `docker ps`, $3 want-exit, $4 want-text
  local dir; dir="$(mktemp -d)"
  make_bucket "$dir" 3
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    printf '  ps)      printf %s "%s" ;;\n' "'%s'" "$2"
    echo '  inspect) echo tile-lite-elite-preview ;;'
    echo '  run)     echo "(stub) would have written into the volume" ;;'
    echo 'esac'
  } > "$dir/bin/docker"
  chmod +x "$dir/bin/docker"
  local out status
  set +e
  out="$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$SCRIPT" \
          "https://example.invalid/p/x/o/" --into tile-lite-elite-data 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne "$3" ]]; then
    echo "FAIL  $1: exit $status, wanted $3"; echo "      $out"; failures=1
  elif [[ -n "$4" && "$out" != *"$4"* ]]; then
    echo "FAIL  $1: did not mention '$4'"; echo "      $out"; failures=1
  else
    echo "ok    $1"
  fi
  rm -rf "$dir"
}

volume_case "a volume a container still holds is refused" \
            "tile-lite-elite-server-1" 1 "refusing — volume"
volume_case "and it names the container holding it" \
            "tile-lite-elite-server-1" 1 "tile-lite-elite-server-1"
volume_case "and says how to stop it" \
            "tile-lite-elite-server-1" 1 "docker compose -p"
# The half that keeps it from blocking an ordinary restore.
volume_case "a volume nobody holds is restored" "" 0 "loading into volume"

run "a good backup verifies and restores"          3 0 "verified: integrity ok, 3 players"
run "an empty database is refused"                 0 1 "valid database with no players"

# It must pick the newest, not the first or the last listed.
dir="$(mktemp -d)"; make_bucket "$dir" 2
set +e
out="$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$SCRIPT" "https://example.invalid/p/x/o/" 2>&1)"
set -e
[[ "$out" == *"newest backup: db-20260821T030000Z"* ]] \
  && echo "ok    picks the newest by name" \
  || { echo "FAIL  picks the newest: $out"; failures=1; }
rm -rf "$dir"

# A URL that is not the bucket form is a mistake worth catching before it
# produces a confusing 404 from somewhere else.
set +e
out="$(bash "$SCRIPT" "https://example.invalid/p/x/o/some-object" 2>&1)"; status=$?
set -e
[[ "$status" -ne 0 && "$out" == *"end in /o/"* ]] \
  && echo "ok    an object-form URL is rejected with a reason" \
  || { echo "FAIL  object-form URL: $out"; failures=1; }

if (( failures )); then echo; echo "restore-backup.sh: FAILURES"; exit 1; fi
echo; echo "restore-backup.sh: all cases pass"
