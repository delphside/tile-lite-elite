#!/usr/bin/env bats

# deploy.sh's gates. This is the script that decides what reaches users, and
# until these existed its gates were only exercised by deploying, so the branch
# where each gate says no almost never ran. Two gates failed open for exactly
# that reason: check-commit-stamp, which passed everything for weeks, and
# ci-status (#93), which passed the commit released as 0.5.0. A third broke the
# other way (#100, every rehearsal refused) and was found by a person.
#
# DEPLOY_GATES_ONLY=1 runs every gate and stops before the first side effect,
# which is what makes this testable at all.
#
# What is stubbed and what is real:
#   - gh and curl are stubbed; they are what deploy.sh reaches outside the
#     repository before the worktree is created.
#   - `git fetch` is stubbed (#369: thirty real fetches a run, and one slow one
#     killed deploy.sh part-way through). Every other git call is real, against
#     this repository, with historic commits whose CI history the fixtures
#     describe, so a fixture cannot describe something that never happened.
#   - ssh, scp, rsync, docker and cargo are stubs that record and fail, and
#     every case asserts none was called. Nothing here should reach them; if
#     DEPLOY_GATES_ONLY ever stopped stopping, this suite would otherwise run a
#     real production deploy.
#   - XDG_STATE_HOME is the scratch directory, so the run record deploy.sh
#     writes does not join the real ones.
#
# CI checks out with fetch-depth: 0 for these commits.

GOOD_COMMIT=8a5d71d   # released as 0.5.1: push-to-main run green, e2e included
BAD_COMMIT=3d821e9    # released as 0.5.0: main run cancelled, PR run failed

setup_file() {
  export ROOT="$BATS_TEST_DIRNAME/../.."
  TAB=$'\t'
  row() { printf '%s\t%s\t%s\t%s\t%s\t%s' "$@"; }
  # Four runs for BAD_COMMIT, exactly as GitHub recorded them.
  export FOUR_RUNS="$(row 31418814759 push prod-0.5.0 completed success https://example/tag)
$(row 31418632931 push main completed cancelled https://example/main)
$(row 31417859025 pull_request 0.5.0 completed failure https://example/pr)
$(row 31417856444 push 0.5.0 completed success https://example/branch)"
  export GREEN_MAIN="$(row 900 push main completed success https://example/main)"
  export PR_FAILED="$GREEN_MAIN
$(row 901 pull_request some-branch completed failure https://example/pr)"
  export BRANCH_RUN="$(row 902 push some-branch completed success https://example/branch)"
  export GREEN_JOBS="fmt · clippy · test · wasm${TAB}success
commit stamp (app/api versions)${TAB}success
e2e (Playwright · preview stack)${TAB}success"
  export SKIPPED_E2E="fmt · clippy · test · wasm${TAB}success
e2e (Playwright · preview stack)${TAB}skipped"
}

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
}

health_for() { printf '%s {"status":"ok","app_version":"%s","schema_version":%s}' "$1" "$2" "$3"; }

# Every environment on the commit being deployed, with a schema that matches.
all_current() {
  printf '%s\n%s\n%s' "$(health_for prod.test "0.5.1+$1" 6)" \
    "$(health_for preview.test "0.5.1+$1" 6)" "$(health_for rehearsal.test "0.5.1+$1" 6)"
}

# gates <runs> <jobs> <health> <commit> [VAR=value...]: deploy.sh in gates-only
# mode, with the stubs above. <health> is one "<url substring> <json>" a line.
gates() {
  local runs="$1" jobs="$2" health="$3" commit="$4"; shift 4
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '%s\n' "$runs" > "$BATS_TEST_TMPDIR/runs"
  printf '%s\n' "$jobs" > "$BATS_TEST_TMPDIR/jobs"
  printf '%s\n' "$health" > "$BATS_TEST_TMPDIR/health"
  # Dispatch on the endpoint, not just on `gh api`: ci-status.sh reads runs
  # and jobs, deploy.sh counts pull requests, check-release-version.sh reads
  # milestone issues. Answering one with another's data made a release-kind
  # check see a jobs table and refuse.
  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *actions/runs*/jobs*)  cat "$BATS_TEST_TMPDIR/jobs" ;;
  *issues*|*milestones*) : ;;
  api\ *)                : ;;
  *)                     cat "$BATS_TEST_TMPDIR/runs" ;;
esac
STUB
  # /health per URL; anything unlisted is unreachable, exit 7, as curl says for
  # a host that is not there.
  cat > "$bin/curl" <<STUB
#!/usr/bin/env bash
url="\${*: -1}"
while IFS= read -r line; do
  [[ -z "\$line" ]] && continue
  if [[ "\$url" == *"\${line%% *}"* ]]; then printf '%s' "\${line#* }"; exit 0; fi
done < "$BATS_TEST_TMPDIR/health"
exit 7
STUB
  printf '#!/usr/bin/env bash\n[[ "$1" == fetch ]] && exit 0\nexec %s "$@"\n' "$(command -v git)" > "$bin/git"
  local tool
  for tool in ssh scp rsync docker cargo; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/outward"\nexit 1\n' "$tool" "$BATS_TEST_TMPDIR" > "$bin/$tool"
  done
  chmod +x "$bin"/*
  # `timeout`: the CI gate polls with --wait, which is right for a deploy and
  # wrong for a test, where a fixture with no run would wait twenty minutes.
  run bash -c 'cd "$1" && shift && PATH="$1:$PATH" timeout 60 env \
      DEPLOY_GATES_ONLY=1 XDG_STATE_HOME="$2" \
      TARGET_URL=https://prod.test PREVIEW_URL=http://preview.test REHEARSAL_URL=https://rehearsal.test \
      "${@:3}"' _ "$ROOT" "$bin" "$BATS_TEST_TMPDIR/state" "$@" "$ROOT/scripts/application/deliver/deploy.sh" "$commit"
  [[ ! -e "$BATS_TEST_TMPDIR/outward" ]] || fail "reached past the gates: $(cat "$BATS_TEST_TMPDIR/outward")"
}

# --- the CI gate --------------------------------------------------------------

# #93: two of the four runs are green, and neither is the push to main.
@test "a cancelled push-to-main run is refused, whatever other refs say" {
  gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" $BAD_COMMIT
  assert_equal "$status" 1
  assert_output --partial "push on main"
  assert_output --partial cancelled
}

# The run concludes success either way.
@test "a green main run with e2e skipped is refused, naming the job" {
  gates "$GREEN_MAIN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT
  assert_equal "$status" 1
  assert_output --partial e2e
}

# --- the pull-request gate -------------------------------------------------------

@test "a failed pull-request run is refused even when main is green" {
  gates "$PR_FAILED" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT
  assert_equal "$status" 1
  assert_output --partial "pull request"
}

# Absence is a pass, the shape that let 0.5.0 through, so it is said out loud.
@test "no pull-request run is announced, not silently skipped" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT
  assert_output --partial "No pull-request run"
}

# --- the environment gates ---------------------------------------------------------

stale() {   # <which> : every environment current except that one
  local p="0.5.1+$GOOD_COMMIT" v="0.5.1+$GOOD_COMMIT" r="0.5.1+$GOOD_COMMIT"
  case "$1" in preview) v="0.5.0+ffffff0" ;; rehearsal) r="0.5.0+ffffff0" ;; esac
  printf '%s\n%s\n%s' "$(health_for prod.test "$p" 6)" "$(health_for preview.test "$v" 6)" \
    "$(health_for rehearsal.test "$r" 6)"
}

@test "a preview on another commit is refused, naming both" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(stale preview)" $GOOD_COMMIT
  assert_equal "$status" 1
  assert_output --partial "preview is running commit"
}

@test "a rehearsal host on another commit is refused" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(stale rehearsal)" $GOOD_COMMIT
  assert_equal "$status" 1
}

# --- the schema gate: physics, never skippable -------------------------------------
# An image the database has outrun does not boot, so shipping it turns a bug
# into an outage. The one gate an emergency must not get past either.

ahead() {
  printf '%s\n%s\n%s' "$(health_for prod.test "0.5.1+$GOOD_COMMIT" 99)" \
    "$(health_for preview.test "0.5.1+$GOOD_COMMIT" 99)" "$(health_for rehearsal.test "0.5.1+$GOOD_COMMIT" 99)"
}

@test "a database ahead of the image is refused, emergency or not" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(ahead)" $GOOD_COMMIT
  assert_equal "$status" 1
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(ahead)" $GOOD_COMMIT DEPLOY_EMERGENCY=drill
  assert_equal "$status" 1
}

# --- everything green -----------------------------------------------------------------

@test "every gate passing reaches the build, and says nothing was built" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT
  assert_success
  assert_output --partial "stopping before anything is built"
}

# --- emergency: it may skip the two gates that cost an image build, and nothing else

@test "an emergency skips a stale preview and rehearsal, and says so" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(stale preview)" $GOOD_COMMIT DEPLOY_EMERGENCY=drill
  assert_success
  assert_output --partial "Skipping the rehearsal gate (emergency)"
}

# The one that matters most: an emergency is not a way past a failing test.
@test "an emergency still requires CI, and e2e to have run" {
  gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" $BAD_COMMIT DEPLOY_EMERGENCY=drill
  assert_equal "$status" 1
  gates "$GREEN_MAIN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT DEPLOY_EMERGENCY=drill
  assert_output --partial e2e
}

# --- #100: a rehearsal deploy targets a commit usually still on a branch, so
# there is no push-to-main run, and e2e does not run on a branch push at all.

@test "a rehearsal is judged by its own push run, and does not wait for main" {
  gates "$BRANCH_RUN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT DEPLOY_ENV=rehearsal
  assert_success
  assert_output --partial "the 'push' run passed"
}

# --- the gates must be seen to have run -----------------------------------------------
# Owner, 2026-08-15: "something other than the checks needs to monitor the
# checks." deploy.sh counts its own gates and refuses if the checklist is short,
# but that checklist cannot be evidence about itself: delete a gate and its
# entry together and deploy.sh is happy. So these lists are this file's own
# copy of the truth, deliberately not read from deploy.sh. Adding a gate means
# adding it in both places, and that duplication is the point. Read from the
# "Gates run:" line: a gate's name appears elsewhere in the output too, and
# matching anywhere let a gate go unrecorded until 2026-09-27.

@test "every gate ran on a production deploy" {
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT
  local gate
  ran="$(grep '^==> Gates run:' <<< "$output")"
  for gate in on-remote ci pull-request schema version milestone preview rehearsal; do
    assert_regex " $ran " " $gate "
  done
}

# Fewer, on purpose: no preview, no pull-request run, no milestone to close.
@test "the rehearsal's gates ran on a rehearsal deploy" {
  gates "$BRANCH_RUN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" $GOOD_COMMIT DEPLOY_ENV=rehearsal
  local gate
  ran="$(grep '^==> Gates run:' <<< "$output")"
  for gate in on-remote ci schema version; do
    assert_regex " $ran " " $gate "
  done
}

# --- the emergency scope gate (#387 R3) -------------------------------------------------
# Since D55 main accumulates tested but unshipped image changes, and an
# emergency deployed from main ships all of them beside the fix. The gate asks;
# with no terminal, as here, it refuses.
#
# The commits are found, not hardcoded: the newest commit on origin/main that
# ships, by the gate's own `ships` test, and its parent as what production runs.
# Not HEAD: on a project branch the newest such commit is the branch's own
# (400-scheduler-mechanism, 2026-09-25). Not a path pattern: a benchmark's
# result rows under examples/ (2026-09-26) and the post-release version bump
# both touch the image by path and ship nothing.

scope_commits() {
  local ref candidate
  ref="$(git -C "$ROOT" rev-parse --verify --quiet origin/main || echo HEAD)"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/application/deliver/shipping-paths.sh"
  IMG_NEW=""
  while read -r candidate; do
    if REPO_DIR="$ROOT" ships "$candidate"; then IMG_NEW="$candidate"; break; fi
  done < <(git -C "$ROOT" log "$ref" --format=%H -50)
  IMG_OLD="$(git -C "$ROOT" rev-parse --verify --quiet "${IMG_NEW}^" || true)"
  [[ -n "$IMG_NEW" && -n "$IMG_OLD" ]] || skip "no shipping commit with a parent to compare"
}

# The target is main itself, so its extra commits are on main by definition.
# The fix-not-on-main case, the one the drill found, cannot be built from real
# history without a branch that outlives the test.
@test "an emergency carrying unreleased image changes names them, says to cut from the tag, and refuses" {
  scope_commits
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $IMG_OLD)" $IMG_NEW "DEPLOY_EMERGENCY=testing R3"
  assert_equal "$status" 1
  assert_output --partial "also ships image changes"
  assert_output --partial "last released tag"
}

# The half that keeps it from becoming noise.
@test "an ordinary deploy is not asked about scope" {
  scope_commits
  gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $IMG_OLD)" $IMG_NEW
  refute_output --partial "also ships image changes"
}
