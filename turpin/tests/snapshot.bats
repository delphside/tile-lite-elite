#!/usr/bin/env bats

# save-state and restore-state: the snapshot contract of design 545 §2.2.2,
# with the tar and the shell run for real on folders in place of the volume.

setup() {
  load helpers
  common_setup
  a_data_folder
  export STUB_CONTAINER=abc123
  export TURPIN_DEPLOY=3 TURPIN_CURRENT=2
}

@test "save-state refuses with no TLE_SNAPSHOT_DIR, then takes the snapshot once it is set" {
  : > "$TURPIN_STATE/.env"
  run "$HOOKS/save-state"
  assert_failure 1
  assert_output --partial "TLE_SNAPSHOT_DIR is not set"
  echo "TLE_SNAPSHOT_DIR=$SNAP_DIR" > "$TURPIN_STATE/.env"
  run "$HOOKS/save-state"
  assert_success
  [[ -f "$SNAP_DIR/turpin-3.tgz" ]]
}

@test "save-state refuses a relative snapshot folder" {
  echo "TLE_SNAPSHOT_DIR=snapshots" > "$TURPIN_STATE/.env"
  run "$HOOKS/save-state"
  assert_failure 1
  assert_output --partial "not an absolute path"
}

@test "save-state stops the server, tars the volume read-only, and leaves no .partial" {
  run "$HOOKS/save-state"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line "stop abc123"
  assert_line --partial "-v tile-lite-elite-data:/data:ro"
  assert_line --partial "-v $SNAP_DIR:/snapshots --entrypoint tar"
  assert_line --partial "--entrypoint tar $TURPIN_IMAGE_SERVER czf /snapshots/turpin-3.tgz.partial -C /data ."
  [[ ! -e "$SNAP_DIR/turpin-3.tgz.partial" ]]
  # the format rollback.sh --db-only unpacks: a gzip tar of the volume's contents
  run tar tzf "$SNAP_DIR/turpin-3.tgz"
  assert_line "./tile-lite-elite.sqlite3"
}

@test "save-state keeps this deploy's and current's snapshots, removes other turpin-* ones, and never touches pre-*" {
  touch "$SNAP_DIR/turpin-1.tgz" "$SNAP_DIR/turpin-2.tgz" "$SNAP_DIR/turpin-4.tgz.partial" \
    "$SNAP_DIR/pre-0.10.1-2bbb957-20261101T000000Z.tgz"
  run "$HOOKS/save-state"
  assert_success
  [[ ! -e "$SNAP_DIR/turpin-1.tgz" ]]
  [[ ! -e "$SNAP_DIR/turpin-4.tgz.partial" ]]
  [[ -e "$SNAP_DIR/turpin-2.tgz" ]]
  [[ -e "$SNAP_DIR/turpin-3.tgz" ]]
  [[ -e "$SNAP_DIR/pre-0.10.1-2bbb957-20261101T000000Z.tgz" ]]
}

@test "save-state with no current keeps only this deploy's" {
  unset TURPIN_CURRENT
  touch "$SNAP_DIR/turpin-2.tgz"
  run "$HOOKS/save-state"
  assert_success
  [[ ! -e "$SNAP_DIR/turpin-2.tgz" ]]
  [[ -e "$SNAP_DIR/turpin-3.tgz" ]]
}

@test "save-state run again replaces its snapshot with the volume as it is then" {
  run "$HOOKS/save-state"
  assert_success
  echo "game two" > "$DATA_DIR/second.txt"
  run "$HOOKS/save-state"
  assert_success
  run tar tzf "$SNAP_DIR/turpin-3.tgz"
  assert_line "./second.txt"
}

@test "save-state leaves the volume as it was on every role but preview" {
  run "$HOOKS/save-state"
  assert_success
  [[ -f "$DATA_DIR/tile-lite-elite.sqlite3" ]]
}

@test "save-state on preview empties the volume after the snapshot, which still holds it" {
  export TURPIN_ROLE=preview
  run "$HOOKS/save-state"
  assert_success
  [[ -z "$(ls -A "$DATA_DIR")" ]]
  run tar tzf "$SNAP_DIR/turpin-3.tgz"
  assert_line "./tile-lite-elite.sqlite3"
  run cat "$DOCKER_LOG"
  assert_line --partial "-v tile-lite-elite-preview-data:/data"
}

@test "save-state refuses where the tar fails, and leaves no snapshot under its number" {
  echo stale > "$SNAP_DIR/turpin-3.tgz"
  export STUB_RUN_RC=1
  run "$HOOKS/save-state"
  assert_failure 1
  assert_output --partial "could not take the snapshot"
  [[ ! -e "$SNAP_DIR/turpin-3.tgz" ]]
  [[ ! -e "$SNAP_DIR/turpin-3.tgz.partial" ]]
}

@test "save-state: a Docker call that outlasts 120 s refuses" {
  export TIMEOUT_EXPIRES=1
  run "$HOOKS/save-state"
  assert_failure 1
  assert_output --partial "did not finish within 120s"
  [[ ! -e "$SNAP_DIR/turpin-3.tgz" ]]
}

@test "restore-state refuses with no TLE_SNAPSHOT_DIR, then restores once it is set" {
  run "$HOOKS/save-state"
  assert_success
  echo "game two" > "$DATA_DIR/second.txt"
  : > "$TURPIN_STATE/.env"
  run "$HOOKS/restore-state"
  assert_failure 1
  assert_output --partial "TLE_SNAPSHOT_DIR is not set"
  echo "TLE_SNAPSHOT_DIR=$SNAP_DIR" > "$TURPIN_STATE/.env"
  run "$HOOKS/restore-state"
  assert_success
  [[ -f "$DATA_DIR/tile-lite-elite.sqlite3" ]]
  [[ ! -e "$DATA_DIR/second.txt" ]]
}

@test "restore-state stops the server and unpacks the snapshot rollback.sh also reads" {
  run "$HOOKS/save-state"
  assert_success
  : > "$DOCKER_LOG"
  run "$HOOKS/restore-state"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line "stop abc123"
  assert_line --partial "-v $SNAP_DIR:/snapshots:ro"
  assert_line --partial "tar xzf /snapshots/turpin-3.tgz -C /data"
}

@test "restore-state does nothing where the deploy has no complete snapshot" {
  touch "$SNAP_DIR/turpin-3.tgz.partial"
  run "$HOOKS/restore-state"
  assert_success
  assert_output --partial "nothing to restore"
  [[ -f "$DATA_DIR/tile-lite-elite.sqlite3" ]]
  [[ ! -s "$DOCKER_LOG" ]]
}

@test "restore-state run again gives the same volume" {
  run "$HOOKS/save-state"
  assert_success
  run "$HOOKS/restore-state"
  assert_success
  run "$HOOKS/restore-state"
  assert_success
  run cat "$DATA_DIR/tile-lite-elite.sqlite3"
  assert_output "game one"
}

@test "restore-state: a Docker call that outlasts 120 s refuses" {
  touch "$SNAP_DIR/turpin-3.tgz"
  export TIMEOUT_EXPIRES=1
  run "$HOOKS/restore-state"
  assert_failure 1
  assert_output --partial "did not finish within 120s"
}
