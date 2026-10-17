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
  load fixtures
  use_fake_profiles
  # The script finds its application from where it sits, so it runs from a copy
  # in a scratch application whose profile is the fake one's (#485).
  APP="$BATS_TEST_TMPDIR/widget"
  mkdir -p "$APP/scripts" "$APP/docs"
  git init -q "$APP"
  cp -r "$BATS_TEST_DIRNAME/../programme" "$APP/scripts/programme"
  find "$APP/scripts/programme" -name __pycache__ -prune -exec rm -rf {} +
  printf '# 9.1.1 Overview\n\nAn overview.\n\n## One section\n' > "$APP/docs/9.1.1-overview.md"
  printf 'indexed\n' > "$APP/docs/README.md"
  for n in one two; do
    printf '#!/bin/sh\necho "ran fake check %s"\nexit 0\n' "$n" > "$APP/scripts/fake-check-$n.sh"
    chmod +x "$APP/scripts/fake-check-$n.sh"
  done
  (cd "$APP" && python3 scripts/programme/docs/document-map.py --write > /dev/null)
  CHECK="$APP/scripts/programme/docs/check-docs.sh"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  # npx records what it is asked to lint; node stands in for the mermaid parse.
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/npx-args"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$STUBS/npx"
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/node"
  chmod +x "$STUBS/npx" "$STUBS/node"
  LIVE="$BATS_TEST_TMPDIR/programme"
  mkdir -p "$LIVE"
  cp -r "$FAKES/live/applications" "$LIVE/applications"
  CHANGES="$LIVE/applications/widget/3.6.7-changes"
}

placement() { run env PATH="$STUBS:$PATH" PROGRAMME_DIR="$1" "$CHECK"; }

@test "placement: no live checkout fails, naming the path it looked at" {
  placement "$BATS_TEST_TMPDIR/not-cloned"
  assert_failure
  assert_output --partial "$BATS_TEST_TMPDIR/not-cloned"
  refute_output --partial "every change document is in"
}

@test "placement: a checkout with no change documents folder is reported rather than passing empty" {
  placement "$LIVE"
  assert_output --partial "MISSING"
  refute_output --partial "every change document is in"
  # Reported only: the exit status is what a clean folder gives, whatever the
  # other steps make of this machine.
  missing_status=$status
  mkdir -p "$CHANGES"
  placement "$LIVE"
  assert_equal "$status" "$missing_status"
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

@test "placement: the grandfathered list is the technical profile's, not a built-in one" {
  mkdir -p "$CHANGES"
  : > "$CHANGES/old-design.md"
  : > "$CHANGES/25-rate-limiting-test-design.md"
  placement "$LIVE"
  refute_output --partial "STRAY   old-design.md"
  assert_output --partial "STRAY   25-rate-limiting-test-design.md"
}

@test "the application's own checks are the profile's, run in order, and a failure fails the script" {
  mkdir -p "$CHANGES"
  placement "$LIVE"
  assert_success
  assert_output --partial "first fake check"
  assert_output --partial "ran fake check one"
  assert_output --partial "ran fake check two"
  printf '#!/bin/sh\necho "second one is red"\nexit 1\n' > "$APP/scripts/fake-check-two.sh"
  placement "$LIVE"
  assert_failure
  assert_output --partial "second one is red"
}

@test "the linter skips what the profile says besides the programme's own folders" {
  mkdir -p "$CHANGES"
  placement "$LIVE"
  grep -qx '#vendored' "$BATS_TEST_TMPDIR/npx-args"
  grep -qx '#programme' "$BATS_TEST_TMPDIR/npx-args"
  ! grep -qx '#old-crates' "$BATS_TEST_TMPDIR/npx-args"
}

@test "a profile that cannot be read fails the script and says which key" {
  mkdir -p "$CHANGES"
  printf 'application = "widget"\n' > "$BATS_TEST_TMPDIR/bare.toml"
  run env PATH="$STUBS:$PATH" PROGRAMME_DIR="$LIVE" PROGRAMME_PROFILE="$BATS_TEST_TMPDIR/bare.toml" "$CHECK"
  assert_failure
  assert_output --partial "documents.lint_ignore"
}

@test "map: a stale map says so and advises regenerating it" {
  printf '\n## A new section\n' >> "$APP/docs/9.1.1-overview.md"
  placement "$LIVE"
  assert_failure
  assert_output --partial "STALE   the document map"
  assert_output --partial "document-map.py --write"
}

@test "map: a failure that is not staleness shows the real error and does not advise --write" {
  printf '\n## One section\n' >> "$APP/docs/9.1.1-overview.md"
  (cd "$APP" && python3 scripts/programme/docs/document-map.py --write > /dev/null 2>&1 || true)
  placement "$LIVE"
  assert_failure
  assert_output --partial "the document map could not be checked"
  assert_output --partial "duplicate headings"
  refute_output --partial "STALE   the document map"
  refute_output --partial "run ./scripts/programme/docs/document-map.py --write"
}
