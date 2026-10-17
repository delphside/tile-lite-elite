#!/usr/bin/env bats

# .githooks/: this repository's three-file shim in front of the programme's hooks.
#
# core.hooksPath is `.githooks` (not `programme/.githooks`) because a path into the
# submodule does not exist until it is initialised, and git then runs no hook and
# says nothing: an unstamped crate commit went through in a fresh worktree. The
# shim must refuse then, run the programme's hook when there is one, set the
# submodule's own hooks path (a linked worktree's submodule included), and warn
# when the pin is not what is checked out.
#
# The programme is a stub repository whose hooks record what they were run with;
# only its `in-submodule` folder is the real one, since refusing is the point.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  # No global identity on the CI runner, so every commit here names its own.
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PROG_SRC="$BATS_TEST_TMPDIR/programme-src"
  APP="$BATS_TEST_TMPDIR/app"
  LOG="$BATS_TEST_TMPDIR/ran"
  : > "$LOG"
  git init -q "$PROG_SRC"
  # A pin older than the hooks, which every checkout has until it moves.
  git -C "$PROG_SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "before the hooks"
  mkdir -p "$PROG_SRC/.githooks"
  cp -r "$ROOT/programme/.githooks/in-submodule" "$PROG_SRC/.githooks/in-submodule"
  for h in pre-commit commit-msg post-merge; do
    # Only post-merge's input is looked at: the others would wait on a terminal.
    in='""'; [[ "$h" == post-merge ]] && in='"$(cat)"'
    printf '#!/usr/bin/env bash\necho "%s $* stdin=%s" >> "%s"\nexit "${STUB_EXIT:-0}"\n' "$h" "$in" "$LOG" > "$PROG_SRC/.githooks/$h"
    chmod +x "$PROG_SRC/.githooks/$h"
  done
  git -C "$PROG_SRC" add -A
  git -C "$PROG_SRC" -c user.email=t@t -c user.name=t commit -q -m "programme"
  git init -q "$APP"
  git -C "$APP" config user.email t@t
  git -C "$APP" config user.name t
  mkdir -p "$APP/.githooks"
  cp "$ROOT"/.githooks/* "$APP/.githooks/"
  git -C "$APP" add .githooks
  git -C "$APP" commit -q -m "app 0.0.0 api 0.0: shim"
  # git runs a hook at the top of the checkout; so do these cases.
  cd "$APP"
}

# attach: the submodule, as a clone and checkout leave it.
attach() {
  git -C "$APP" submodule add -q "$PROG_SRC" programme
  git -C "$APP" commit -q -m "app 0.0.0 api 0.0: pin" --no-verify
  git -C "$APP" config core.hooksPath .githooks
}

@test "the files are the three hooks and the shim they source, all executable" {
  for f in pre-commit commit-msg post-merge shim.sh; do
    [[ -x "$ROOT/.githooks/$f" ]] || fail "$f is not executable"
  done
  run ls "$ROOT/.githooks"
  assert_output "commit-msg
post-merge
pre-commit
shim.sh"
}

@test "no submodule: a commit is refused, saying how to initialise it" {
  git -C "$APP" config core.hooksPath .githooks
  echo x > "$APP/f"; git -C "$APP" add f
  run git -C "$APP" commit -m "app 0.0.0 api 0.0: x"
  assert_failure
  assert_output --partial "the programme submodule is not initialised: run git submodule update --init"
}

@test "no submodule: pre-commit and commit-msg each refuse, post-merge warns and does not fail" {
  git -C "$APP" config core.hooksPath .githooks
  run "$APP/.githooks/pre-commit"
  assert_equal "$status" 1
  assert_output --partial "git submodule update --init"
  run "$APP/.githooks/commit-msg" "$BATS_TEST_TMPDIR/msg"
  assert_equal "$status" 1
  assert_output --partial "git submodule update --init"
  run "$APP/.githooks/post-merge" 0
  assert_equal "$status" 0
  assert_output --partial "git submodule update --init"
}

@test "an empty programme/ folder, as a fresh worktree has, is the same as none" {
  mkdir -p "$APP/programme"
  git -C "$APP" config core.hooksPath .githooks
  echo x > "$APP/f"; git -C "$APP" add f
  run git -C "$APP" commit -m "app 0.0.0 api 0.0: x"
  assert_failure
  assert_output --partial "not initialised"
}

@test "an initialised submodule: the programme's hook runs, with the arguments and the input" {
  attach
  echo x > "$APP/f"; git -C "$APP" add f
  run git -C "$APP" commit -q -m "app 0.0.0 api 0.0: x"
  assert_success
  grep -q '^pre-commit ' "$LOG"
  grep -q '^commit-msg .*COMMIT_EDITMSG' "$LOG"
  : > "$LOG"
  run bash -c 'printf "hello" | "$1/.githooks/post-merge" 1' _ "$APP"
  assert_success
  grep -qx 'post-merge 1 stdin=hello' "$LOG"
}

@test "the programme's hook refusing refuses the commit, and its status comes through" {
  attach
  echo x > "$APP/f"; git -C "$APP" add f
  STUB_EXIT=1 run git -C "$APP" commit -q -m "app 0.0.0 api 0.0: x"
  assert_failure
  [[ "$(git -C "$APP" log --oneline | wc -l)" -eq 2 ]]
}

@test "the shim sets the submodule's own hooks path, and puts it back if it is lost" {
  attach
  [[ -z "$(git -C "$APP/programme" config --get core.hooksPath || true)" ]]
  run "$APP/.githooks/pre-commit"
  assert_success
  run git -C "$APP/programme" config --get core.hooksPath
  assert_output ".githooks/in-submodule"
  git -C "$APP/programme" config --unset core.hooksPath
  run "$APP/.githooks/pre-commit"
  run git -C "$APP/programme" config --get core.hooksPath
  assert_output ".githooks/in-submodule"
}

@test "with the hooks path set by the shim, a commit inside the submodule is refused" {
  attach
  run "$APP/.githooks/pre-commit"
  echo y > "$APP/programme/g"; git -C "$APP/programme" add g
  run git -C "$APP/programme" commit -m "inside"
  assert_failure
  assert_output --partial "commit refused"
}

@test "in a linked worktree too: the shim sets that submodule's path and the commit inside is refused" {
  attach
  git -C "$APP" worktree add -q "$BATS_TEST_TMPDIR/wt" -b other
  git -C "$BATS_TEST_TMPDIR/wt" submodule update -q --init
  WT="$BATS_TEST_TMPDIR/wt"
  [[ -z "$(git -C "$WT/programme" config --get core.hooksPath || true)" ]]
  echo x > "$WT/f"; git -C "$WT" add f
  run git -C "$WT" commit -q -m "app 0.0.0 api 0.0: from the worktree"
  assert_success
  run git -C "$WT/programme" config --get core.hooksPath
  assert_output ".githooks/in-submodule"
  echo y > "$WT/programme/g"; git -C "$WT/programme" add g
  run git -C "$WT/programme" commit -m "inside"
  assert_failure
  assert_output --partial "commit refused"
}

@test "a linked worktree whose submodule is not initialised is refused, not run with no hook" {
  attach
  git -C "$APP" worktree add -q "$BATS_TEST_TMPDIR/wt" -b other
  echo x > "$BATS_TEST_TMPDIR/wt/f"; git -C "$BATS_TEST_TMPDIR/wt" add f
  run git -C "$BATS_TEST_TMPDIR/wt" commit -m "app 0.0.0 api 0.0: x"
  assert_failure
  assert_output --partial "not initialised"
}

@test "the submodule off the recorded commit is warned about, and the hook still runs" {
  attach
  git -C "$PROG_SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "later"
  git -C "$APP/programme" fetch -q origin
  git -C "$APP/programme" checkout -q FETCH_HEAD
  run "$APP/.githooks/pre-commit"
  assert_success
  assert_output --partial "warning: programme/ is at"
  assert_output --partial "run git submodule update"
  grep -q '^pre-commit' "$LOG"
}

@test "the submodule at the recorded commit gets no warning" {
  attach
  run "$APP/.githooks/pre-commit"
  assert_success
  refute_output --partial "warning"
}

@test "a commit that moves the pin is not warned about: the index's commit is the one that counts" {
  attach
  git -C "$PROG_SRC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "later"
  git -C "$APP/programme" fetch -q origin
  git -C "$APP/programme" checkout -q FETCH_HEAD
  git -C "$APP" add programme
  run "$APP/.githooks/pre-commit"
  assert_success
  refute_output --partial "warning"
}

@test "the pin of a checkout that predates the hooks says the submodule is not at the recorded commit, not that it is uninitialised" {
  attach
  git -C "$APP/programme" checkout -q "$(git -C "$PROG_SRC" rev-list --max-parents=0 HEAD)"
  [[ ! -e "$APP/programme/.githooks" ]]
  echo x > f; git add f
  run git commit -m "app 0.0.0 api 0.0: x"
  assert_failure
  assert_output --partial "not the commit this repository records"
  assert_output --partial "run git submodule update"
  refute_output --partial "not initialised"
  run .githooks/post-merge 0
  assert_success
  assert_output --partial "not the commit this repository records"
}

@test "under an absolute core.hooksPath, as the live checkout sets, a linked worktree is judged by its own submodule" {
  attach
  git config core.hooksPath "$APP/.githooks"
  git worktree add -q "$BATS_TEST_TMPDIR/wt" -b other
  # The main checkout has the programme; the worktree has not initialised its own.
  echo x > "$BATS_TEST_TMPDIR/wt/f"; git -C "$BATS_TEST_TMPDIR/wt" add f
  run git -C "$BATS_TEST_TMPDIR/wt" commit -m "app 0.0.0 api 0.0: x"
  assert_failure
  assert_output --partial "not initialised"
  [[ ! -s "$LOG" ]]
  # and once it has, its own hook runs, not the main checkout's
  git -C "$BATS_TEST_TMPDIR/wt" submodule update -q --init
  run git -C "$BATS_TEST_TMPDIR/wt" commit -q -m "app 0.0.0 api 0.0: x"
  assert_success
  grep -q '^pre-commit' "$LOG"
  run git -C "$BATS_TEST_TMPDIR/wt/programme" config --get core.hooksPath
  assert_output ".githooks/in-submodule"
  # the main checkout's submodule was not the one touched
  [[ -z "$(git -C "$APP/programme" config --get core.hooksPath || true)" ]]
}

# What the setup scripts configure: taken from them, so a line added there is tested.
setup_config() {   # <repo>: apply every `git config key value` line of the two setup scripts
  local f line
  for f in "$ROOT/scripts/develop/setup-dev-environment.sh" "$ROOT/.claude/cloud-setup.sh"; do
    while read -r line; do
      # shellcheck disable=SC2086
      git -C "$1" config ${line#git config } || true
    done < <(grep -E '^git config [A-Za-z.]+ [^ ]+( \|\| .*)?$' "$f" | sed -E 's/ \|\| .*//')
  done
}

@test "configured as the setup scripts do, a fresh linked worktree whose submodule is not initialised survives reset --hard, switch and status" {
  attach
  setup_config "$APP"
  [[ "$(git config --get core.hooksPath)" == .githooks ]]
  git worktree add -q "$BATS_TEST_TMPDIR/wt" -b other
  run git -C "$BATS_TEST_TMPDIR/wt" status
  assert_success
  run git -C "$BATS_TEST_TMPDIR/wt" reset --hard
  assert_success
  run git -C "$BATS_TEST_TMPDIR/wt" switch -q -c third
  assert_success
  run git -C "$BATS_TEST_TMPDIR/wt" status --short
  assert_success
}

@test "the setup scripts do not turn submodule.recurse on" {
  run grep -n 'git config submodule.recurse' "$ROOT/scripts/develop/setup-dev-environment.sh" "$ROOT/.claude/cloud-setup.sh"
  assert_failure
}
