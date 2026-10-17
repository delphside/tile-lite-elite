#!/usr/bin/env bats

# .claude/inbox-hook.sh, the SessionStart summary. Owner, 2026-09-27: "can you
# add a hook so you notice a new report?" The workflows report by writing an
# issue as the github-actions bot, so the hook has to pass on the inbox's
# Reports section, and say nothing about reports when there are none.
#
# Run from a copy of the hook in a scratch directory whose scripts/ are stubs,
# so the cases are about the hook, not about GitHub.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  F="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$F/.claude" "$F/scripts/programme/board" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/../../.claude/inbox-hook.sh" "$F/.claude/"
  for s in board-actions.py board-check.py board-practices.py; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$F/scripts/programme/board/$s"
  done
  # How the owner is named is the programme file's, asked of board-profile.py.
  printf 'import sys\nsys.exit(print("Pat") if sys.argv[1:] == ["get", "accounts.owner_name"] else 1)\n' \
    > "$F/scripts/programme/board/board-profile.py"
  # The hook only asks that gh exists.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$F/scripts/programme/board/"* "$BATS_TEST_TMPDIR/bin/gh"
}

inbox() {   # what the stub board-inbox.py prints
  printf '#!/usr/bin/env bash\ncat <<'"'"'OUT'"'"'\n%s\nOUT\n' "$1" > "$F/scripts/programme/board/board-inbox.py"
  chmod +x "$F/scripts/programme/board/board-inbox.py"
}

context() {
  run bash -c 'PATH="$1:$PATH" "$2/.claude/inbox-hook.sh" | python3 -c "import json,sys; print(json.load(sys.stdin)[\"hookSpecificOutput\"][\"additionalContext\"])"' \
    _ "$BATS_TEST_TMPDIR/bin" "$F"
}

@test "a report the workflows wrote reaches the session's context" {
  inbox 'INBOX  since 2026-09-20

REPORTS FROM THE SCHEDULED WORKFLOWS
  #384   open    2026-09-26T06:15  Dependency advisories need review

OPENED OR CLOSED
  nothing opened or closed'
  context
  assert_output --partial "reports from the scheduled workflows"
  assert_output --partial "#384   open    2026-09-26T06:15  Dependency advisories need review"
}

@test "no report says nothing about reports" {
  inbox 'INBOX  since 2026-09-20

REPORTS FROM THE SCHEDULED WORKFLOWS
  no report opened, updated or closed

OPENED OR CLOSED
  #9     opened        something'
  context
  refute_output --partial "reports from the scheduled workflows"
  assert_output --partial "#9"
}

@test "the owner is named as the programme file names him" {
  inbox 'INBOX  since 2026-09-20

#7  seven
  > 2026-10-01T09:00  a question'
  context
  assert_output --partial "comments from Pat not yet answered"
}

@test "with no programme file it says the owner and the session still starts" {
  inbox 'INBOX  since 2026-09-20

#7  seven
  > 2026-10-01T09:00  a question'
  rm "$F/scripts/programme/board/board-profile.py"
  context
  assert_success
  assert_output --partial "comments from the owner not yet answered"
}
