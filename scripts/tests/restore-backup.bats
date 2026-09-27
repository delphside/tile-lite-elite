#!/usr/bin/env bats

# restore-backup.sh, against a stubbed curl serving a real gzipped SQLite file.
#
# The cases that matter are the ones where it must refuse. A restore that
# quietly proceeds with a bad file is worse than one that fails, because the
# failure is discovered later and by then the good copy may be gone.
#
# docker is stubbed in every case, not only the volume ones: `--into
# tile-lite-elite-data` names the real local development volume, and a broken
# guard with the real docker would empty it.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  command -v sqlite3 >/dev/null || skip "sqlite3 is not installed"
  SCRIPT="$BATS_TEST_DIRNAME/../restore-backup.sh"
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/bucket" "$D/bin"
  HOLDERS=""
}

bucket() {   # <players>: a listing, and one object which is a real database
  sqlite3 "$D/db.sqlite3" "create table players(id text); create table games(id text);"
  local i
  for ((i = 0; i < $1; i++)); do sqlite3 "$D/db.sqlite3" "insert into players values ('p$i');"; done
  gzip -c "$D/db.sqlite3" > "$D/bucket/db-20260821T030000Z.sqlite3.gz"
  printf '%s' '{"objects":[{"name":"db-20260820T030000Z.sqlite3.gz"},{"name":"db-20260821T030000Z.sqlite3.gz"}]}' \
    > "$D/bucket/list.json"
  cat > "$D/bin/curl" <<STUB
#!/usr/bin/env bash
url="\${@: -1}"
echo "\$url" >> "$D/curl-calls"
case "\$url" in
  */o/)          cat "$D/bucket/list.json" ;;
  *db-20260821*) cat "$D/bucket/db-20260821T030000Z.sqlite3.gz" ;;
  *)             exit 22 ;;
esac
STUB
  cat > "$D/bin/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  ps)      printf '%s' "$HOLDERS" ;;
  inspect) echo tile-lite-elite-preview ;;
  run)     echo "(stub) would have written into the volume" ;;
esac
STUB
  chmod +x "$D/bin/curl" "$D/bin/docker"
}

restore() { run bash -c 'cd "$1" && PATH="$1/bin:$PATH" bash "${@:2}"' _ "$D" "$SCRIPT" "$@"; }

# #385. The case with no error to catch: replacing the database under a live
# connection succeeds, since POSIX keeps the unlinked inode alive, so nothing
# fails until the next restart, by which time the good copy may be gone. The
# refusal is the only thing standing between those two moments.
@test "a volume a container still holds is refused, naming it and saying how to stop it" {
  HOLDERS=tile-lite-elite-server-1
  bucket 3
  restore "https://example.invalid/p/x/o/" --into tile-lite-elite-data
  assert_equal "$status" 1
  assert_output --partial "refusing — volume"
  assert_output --partial "tile-lite-elite-server-1"
  assert_output --partial "docker compose -p"
  refute_output --partial "would have written"
}

# The half that keeps it from blocking an ordinary restore.
@test "a volume nobody holds is restored" {
  bucket 3
  restore "https://example.invalid/p/x/o/" --into tile-lite-elite-data
  assert_success
  assert_output --partial "loading into volume"
}

@test "a good backup verifies and restores" {
  bucket 3
  restore "https://example.invalid/p/x/o/"
  assert_success
  assert_output --partial "verified: integrity ok, 3 players"
}

@test "an empty database is refused" {
  bucket 0
  restore "https://example.invalid/p/x/o/"
  assert_equal "$status" 1
  assert_output --partial "valid database with no players"
}

@test "it picks the newest backup by name, not the first or last listed" {
  bucket 2
  restore "https://example.invalid/p/x/o/"
  assert_output --partial "newest backup: db-20260821T030000Z"
}

# A URL that is not the bucket form is a mistake worth catching before it
# produces a confusing 404 from somewhere else.
@test "an object-form URL is rejected with a reason" {
  bucket 1
  restore "https://example.invalid/p/x/o/some-object"
  assert_failure
  # The refusal's own line: the usage text says "end in /o/" too, and matching
  # that let a broken check pass until 2026-09-27.
  assert_output --partial "error: the PAR URL should end in /o/"
  # And before anything is fetched.
  assert [ ! -e "$D/curl-calls" ]
}
