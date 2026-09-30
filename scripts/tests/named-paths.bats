#!/usr/bin/env bats

# Every scripts/ path the hooks, Claude's hooks and the workflows name exists.
#
# Most of those calls end in `|| true` or `2>/dev/null`, or test `-x` first, so
# a wrong path fails quietly: the hook or workflow carries on having checked
# nothing. The move into scripts/programme/ (#421) changed every one of them,
# and nothing else would notice one left behind.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# named_paths <root>: each distinct scripts/... path or glob named in those files.
named_paths() {
  local root="$1"
  grep -ohE 'scripts/[A-Za-z0-9_./*-]*[A-Za-z0-9_*]' \
    "$root"/.githooks/* "$root"/.claude/*.sh "$root"/.github/workflows/*.yml \
    | sort -u
}

# missing <root>: the named paths that do not exist in <root>.
missing() {
  local root="$1" p
  while read -r p; do
    compgen -G "$root/$p" > /dev/null || echo "$p"   # a glob, as a comment may name one, must match something
  done < <(named_paths "$root")
}

@test "the hooks and workflows name some scripts/ paths at all" {
  run named_paths "$ROOT"
  assert_success
  assert_line --partial 'scripts/programme/board/board-refs.py'
}

@test "every scripts/ path the hooks and workflows name exists" {
  run missing "$ROOT"
  assert_success
  assert_output ''
}

# The check itself, against a copy with one path broken.
@test "a named path that does not exist is reported" {
  local copy="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$copy/.githooks" "$copy/.claude" "$copy/.github/workflows" "$copy/scripts"
  printf 'python3 "$(dirname "$0")/../scripts/board-refs.py"\n' > "$copy/.githooks/commit-msg"
  printf './scripts/here.sh\n' > "$copy/.claude/x.sh"
  : > "$copy/scripts/here.sh"
  printf 'run: ./scripts/here.sh\n' > "$copy/.github/workflows/w.yml"
  run missing "$copy"
  assert_output 'scripts/board-refs.py'
}
