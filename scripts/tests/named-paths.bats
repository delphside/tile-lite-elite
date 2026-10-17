#!/usr/bin/env bats

# Every scripts/ path that Claude's session hook and the workflows name exists, and
# so does every hook that .claude/settings.json runs.
#
# Most of those calls end in `|| true` or `2>/dev/null`, or test `-x` first, so
# a wrong path fails quietly: the hook or workflow carries on having checked
# nothing. The moves into scripts/programme/ (#421), then out of it into the
# `programme/` submodule and Tile Lite Elite's four folders (#485), changed every
# one of them, and nothing else would notice one left behind. The programme's
# own hooks and git hooks are in the submodule and name paths of their own
# tree; the programme repository's CI tests those.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# named_paths <root>: each distinct scripts/... path or glob named in those files
# and in e2e/, with the `programme/` in front of it when it is the submodule's.
# e2e builds some with path.join('..', 'scripts', 'develop', 'x.sh'), which no
# `scripts/` pattern sees, so those are joined first.
named_paths() {
  local root="$1" files=()
  mapfile -t files < <(find "$root/e2e" -path '*/node_modules' -prune -o -type f \( -name '*.ts' -o -name package.json \) -print 2>/dev/null)
  {
    grep -sohE '(programme/)?scripts/[A-Za-z0-9_./*-]*[A-Za-z0-9_*]' \
      "$root"/.claude/*.sh "$root"/.github/workflows/*.yml "${files[@]}" /dev/null
    grep -sohE "'scripts'(, *'[^']+')+" "${files[@]}" /dev/null | sed -E "s/', *'/\//g; s/'//g"
  } | sort -u
}

# missing <root>: the named paths that do not exist in <root>.
missing() {
  local root="$1" p
  while read -r p; do
    compgen -G "$root/$p" > /dev/null || echo "$p"   # a glob, as a comment may name one, must match something
  done < <(named_paths "$root")
}

# hooks <root>: the file each hook command in settings.json runs. A command that
# goes through the wrapper, `.claude/programme-hook.sh <name> ...`, runs
# programme/.claude/hooks/<name>; the wrapper itself is listed too.
hooks() {
  grep -oE '"command": *"[^"]*(\\"[^"]*)*"' "$1/.claude/settings.json" \
    | sed -E 's/^"command": *"//; s/"$//; s/\\"//g; s/^\$CLAUDE_PROJECT_DIR//; s#^/##' \
    | awk '{ if ($1 == ".claude/programme-hook.sh") { print $1; print "programme/.claude/hooks/" $2 } else print $1 }' \
    | sort -u
}

@test "the session hook and workflows name some scripts/ paths at all" {
  run named_paths "$ROOT"
  assert_success
  assert_line --partial 'programme/scripts/board/board-stage.py'
  assert_line --partial 'scripts/deliver/check-commit-stamp.sh'
}

@test "every scripts/ path they name exists" {
  run missing "$ROOT"
  assert_success
  assert_output ''
}

@test "every hook settings.json runs exists and can be run" {
  run hooks "$ROOT"
  assert_success
  assert_line '.claude/programme-hook.sh'
  assert_line 'programme/.claude/hooks/inbox-hook.sh'
  assert_line 'programme/.claude/hooks/turn-check.sh'
  assert_line 'programme/.claude/hooks/comment-check.sh'
  local h
  for h in $output; do
    [[ -x "$ROOT/$h" ]] || fail "$h is not an executable file"
  done
}

# The check itself, against a copy with one path broken.
@test "a named path that does not exist is reported" {
  local copy="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$copy/.claude" "$copy/.github/workflows" "$copy/scripts"
  printf 'python3 "$ROOT/programme/scripts/board/board-refs.py"\n' > "$copy/.claude/x.sh"
  printf './scripts/here.sh\n' >> "$copy/.claude/x.sh"
  : > "$copy/scripts/here.sh"
  printf 'run: ./scripts/here.sh\n' > "$copy/.github/workflows/w.yml"
  run missing "$copy"
  assert_output 'programme/scripts/board/board-refs.py'
}

# e2e builds a path from pieces, which is how global-teardown.ts missed the move.
@test "a path e2e builds with path.join is checked too" {
  local copy="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$copy/.claude" "$copy/.github/workflows" "$copy/e2e" "$copy/scripts/develop"
  : > "$copy/scripts/develop/e2e-clean.sh"
  printf "path.join(__dirname, '..', 'scripts', 'develop', 'e2e-clean.sh')\n" > "$copy/e2e/ok.ts"
  run missing "$copy"
  assert_output ''
  printf "path.join(__dirname, '..', 'scripts', 'e2e-clean.sh')\n" > "$copy/e2e/old.ts"
  run missing "$copy"
  assert_output 'scripts/e2e-clean.sh'
}

@test "the real e2e/ names the scripts it runs, at their new paths" {
  run named_paths "$ROOT"
  assert_line 'scripts/develop/e2e-clean.sh'
}

# The wrapper settings.json runs: a Claude hook never fails the session.
@test "programme-hook.sh: with no submodule it says so in one line and exits 0" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj"
  run env CLAUDE_PROJECT_DIR="$proj" "$ROOT/.claude/programme-hook.sh" turn-check.sh --reseed-bodies
  assert_success
  assert_output --partial "programme submodule is not initialised"
  assert_output --partial "git submodule update --init"
  [[ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]]
}

@test "programme-hook.sh: with the submodule it runs the hook with the arguments and the input" {
  local proj="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$proj/programme/.claude/hooks"
  printf '#!/usr/bin/env bash\necho "args=$* input=$(cat)"\n' > "$proj/programme/.claude/hooks/x.sh"
  chmod +x "$proj/programme/.claude/hooks/x.sh"
  run bash -c 'printf data | CLAUDE_PROJECT_DIR="$1" "$2/.claude/programme-hook.sh" x.sh a b' _ "$proj" "$ROOT"
  assert_success
  assert_output "args=a b input=data"
}

# A job that runs a script that reaches into programme/ needs the submodule checked
# out. Without it check-commit-stamp.sh failed and touches_image_range read the
# missing script as "no", so e2e was skipped on pull requests that reach the image.
# A workflow's checkout leaves programme/ empty unless it says `submodules: true`.
needs_submodule() {   # <workflow file>: each job that uses programme/ and does not check it out
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
head, _, jobs = ("\n" + text).partition("\njobs:\n")
parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", jobs)
for name, body in zip(parts[1::2], parts[2::2]):
    code = "\n".join(l for l in body.splitlines() if not l.lstrip().startswith("#"))
    uses = re.search(r"programme/|scripts/(deliver|develop|operate|measure)/|scripts/tests|check-docs", code)
    if uses and "submodules: true" not in code:
        print(f"{name} (uses {uses.group(0)})")
PY
}

@test "every workflow job that runs a script reaching into programme/ checks the submodule out" {
  local f
  for f in "$ROOT"/.github/workflows/*.yml; do
    run needs_submodule "$f"
    assert_success
    [[ -z "$output" ]] || fail "$(basename "$f"): $output"
  done
}

@test "a job that uses programme/ without the submodule is reported" {
  printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n      - run: ./scripts/deliver/check-commit-stamp.sh\n  b:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          submodules: true\n      - run: ./scripts/deliver/check-commit-stamp.sh\n  c:\n    steps:\n      - run: echo hi\n' > "$BATS_TEST_TMPDIR/w.yml"
  run needs_submodule "$BATS_TEST_TMPDIR/w.yml"
  assert_output "a (uses scripts/deliver/)"
}
