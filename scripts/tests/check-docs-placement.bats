#!/usr/bin/env bats

# check-docs.sh, step 3: this application's change documents are in the
# programme repository's live checkout (#485), so the placement check reads them
# there, and stops, saying where it looked, when the checkout is not. What it
# finds in the programme's content is reported and does not change the exit
# status (it becomes a gate in the programme's own CI, stage 2 of #485).
#
# npx and node are stubbed so that the lint and the mermaid parse do not run
# (they need the network and 146MB); the other steps run for real and are not
# asserted on.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  CHECK="$BATS_TEST_DIRNAME/../programme/docs/check-docs.sh"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  for c in npx node; do printf '#!/bin/sh\nexit 0\n' > "$STUBS/$c"; chmod +x "$STUBS/$c"; done
  LIVE="$BATS_TEST_TMPDIR/programme"
  CHANGES="$LIVE/applications/tile-lite-elite/3.1.7-changes"
}

placement() { run env PATH="$STUBS:$PATH" PROGRAMME_DIR="$1" "$CHECK"; }

@test "placement: no live checkout fails, naming the path it looked at" {
  placement "$BATS_TEST_TMPDIR/not-cloned"
  assert_failure
  assert_output --partial "$BATS_TEST_TMPDIR/not-cloned"
  refute_output --partial "every change document is in"
}

@test "placement: a checkout with no change documents folder is reported rather than passing empty" {
  mkdir -p "$LIVE"
  placement "$LIVE"
  assert_output --partial "MISSING"
  refute_output --partial "every change document is in"
}

@test "placement: a stray document at the top of the folder is reported" {
  mkdir -p "$CHANGES"
  : > "$CHANGES/README.md"
  : > "$CHANGES/stray-note.md"
  placement "$LIVE"
  assert_output --partial "STRAY   stray-note.md"
  # Reported only: the exit status is what a clean folder gives, whatever the
  # other steps make of this machine.
  stray_status=$status
  rm "$CHANGES/stray-note.md"
  placement "$LIVE"
  assert_equal "$status" "$stray_status"
}

@test "placement: the grandfathered documents and the folders are in place" {
  mkdir -p "$CHANGES/workstreams/a/1-x"
  : > "$CHANGES/README.md"
  : > "$CHANGES/workstreams/a/1-x/1-design.md"
  placement "$LIVE"
  assert_success
  assert_output --partial "every change document is in an issue or release folder"
}
