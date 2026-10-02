#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/deploy.sh's gates, under the same `set -euo pipefail` the
# script itself runs with.
#
# This is the script that decides what reaches users, and until now its gates
# were only ever exercised by deploying. That means the branch where each gate
# says **no** almost never ran: you do not rehearse a deploy against a commit
# you expect to be refused. Two gates have already failed open here for exactly
# that reason — check-commit-stamp, which passed everything for weeks, and
# ci-status (#93), which passed the commit released as 0.5.0 — and a third
# broke in the other direction (#100, every rehearsal refused) and was found by
# a person running a deploy, not by a test.
#
# `DEPLOY_GATES_ONLY=1` runs every gate and stops before the first side effect,
# which is what makes this testable at all.
#
# What is stubbed and what is real:
#
#   - `gh` and `curl` are stubbed. They are the only things deploy.sh reaches
#     for outside the repository before the worktree is created.
#   - git is **real**, against this repository. The commits named below are
#     historic and their CI history is what the fixtures describe, so a
#     fixture cannot drift into describing a situation that never happened —
#     the failure mode of invented ones.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY="$HERE/scripts/deploy.sh"
failures=0
TAB="$(printf '\t')"

# Real commits from this repository. They are not carrying fixture data — the
# run tables below are written here — but the gates need a commit that exists,
# is on a remote branch, and has a version and schema to read. Using real ones
# keeps git honest while everything outside the repository is stubbed.
#
# This is why CI checks out with `fetch-depth: 0`. A shallow clone does not
# have them, and the suite fails with "not a valid local git ref".
GOOD_COMMIT="8a5d71d"      # released as 0.5.1: push-to-main run green, e2e included
BAD_COMMIT="3d821e9"       # released as 0.5.0: main run cancelled, PR run failed

# Builds a bin/ containing stubbed `gh` and `curl`, runs deploy.sh in
# gates-only mode, and returns its exit status.
#
#   $1  runs table for `gh run list`   (id, event, branch, status, conclusion, url)
#   $2  jobs table for `gh api .../jobs` (name, conclusion)
#   $3  health per URL, one "<substring> <json>" per line
#   $4  commit to deploy
#   rest: extra environment assignments
run_gates() {
  local runs="$1" jobs="$2" health="$3" commit="$4"
  shift 4
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"

  # Dispatch on the endpoint, not just on `gh api`. deploy.sh reaches gh through
  # three different callers — ci-status.sh for runs and jobs, its own
  # pull-request count, and check-release-version.sh for milestone issues — and
  # answering one of them with another's data is not a stub, it is noise. That
  # mistake made a release-kind check see a jobs table and refuse.
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    printf '  *actions/runs*/jobs*) printf %s "%s" ;;\n' "'%s\n'" "$jobs"
    echo '  *issues*|*milestones*) : ;;   # no functional issues in the milestone'
    echo '  api\ *) : ;;'
    printf '  *) printf %s "%s" ;;\n' "'%s\n'" "$runs"
    echo 'esac'
  } > "$bin/gh"

  {
    echo '#!/usr/bin/env bash'
    echo '# Answers /health per URL. Anything unlisted is unreachable (exit 7),'
    echo '# which is what curl does for a host that is not there.'
    echo 'url="${*: -1}"'
    printf 'while IFS= read -r line; do\n'
    printf '  [[ -z "$line" ]] && continue\n'
    printf '  match="${line%%%% *}"; body="${line#* }"\n'
    printf '  if [[ "$url" == *"$match"* ]]; then printf %s "$body"; exit 0; fi\n' "'%s'"
    printf 'done <<'"'"'HEALTH'"'"'\n%s\nHEALTH\n' "$health"
    echo 'exit 7'
  } > "$bin/curl"

  chmod +x "$bin/gh" "$bin/curl"

  # `timeout` so a case that waits fails instead of hanging the suite. The CI
  # gate polls with `--wait`, which is right for a deploy — a run may not have
  # started yet — and wrong for a test: a fixture with no run would sit here
  # for twenty minutes. That is behaviour ci-status.test.sh checks directly,
  # without --wait in the way.
  (
    cd "$HERE"
    PATH="$bin:$PATH" \
      timeout 60 \
      env DEPLOY_GATES_ONLY=1 \
      TARGET_URL="https://prod.test" \
      PREVIEW_URL="http://preview.test" \
      REHEARSAL_URL="https://rehearsal.test" \
      "$@" "$DEPLOY" "$commit" 2>&1
  )
  local status=$?
  rm -rf "$dir"
  return $status
}

check_exit() {
  local name="$1" want="$2"
  shift 2
  local got=0
  "$@" > /dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want, got $got"
    failures=$((failures + 1))
  fi
}

check_says() {
  local name="$1" want="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "$out" == *"$want"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: output did not mention '$want'"
    echo "     got: ${out:0:800}"
    failures=$((failures + 1))
  fi
}

row() { printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6"; }
health_for() { printf '%s {"status":"ok","app_version":"%s","schema_version":%s}' "$1" "$2" "$3"; }

# The fixtures. Four runs for BAD_COMMIT, exactly as GitHub recorded them.
FOUR_RUNS="$(row 31418814759 push prod-0.5.0 completed success https://example/tag)
$(row 31418632931 push main completed cancelled https://example/main)
$(row 31417859025 pull_request 0.5.0 completed failure https://example/pr)
$(row 31417856444 push 0.5.0 completed success https://example/branch)"

GREEN_MAIN="$(row 900 push main completed success https://example/main)"
GREEN_JOBS="fmt · clippy · test · wasm${TAB}success
commit stamp (app/api versions)${TAB}success
e2e (Playwright · preview stack)${TAB}success"
SKIPPED_E2E="fmt · clippy · test · wasm${TAB}success
e2e (Playwright · preview stack)${TAB}skipped"

# Every environment on the commit being deployed, and a schema that matches.
all_current() {
  printf '%s\n%s\n%s' \
    "$(health_for prod.test      "0.5.1+$1" 6)" \
    "$(health_for preview.test   "0.5.1+$1" 6)" \
    "$(health_for rehearsal.test "0.5.1+$1" 6)"
}

# --- the CI gate ------------------------------------------------------------

check_exit "a cancelled push-to-main run is refused" 1 \
  run_gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" "$BAD_COMMIT"
check_says "and names the run it judged" "push on main" \
  run_gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" "$BAD_COMMIT"

# The regression #93 was about: two of those four runs are green.
check_says "a green run on another ref does not vouch for main" "cancelled" \
  run_gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" "$BAD_COMMIT"

# A green run whose e2e never ran. The run concludes success either way.
check_exit "a green main run with e2e skipped is refused" 1 \
  run_gates "$GREEN_MAIN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"
check_says "and says which job" "e2e" \
  run_gates "$GREEN_MAIN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"

# --- the pull-request gate ---------------------------------------------------

PR_FAILED="$GREEN_MAIN
$(row 901 pull_request some-branch completed failure https://example/pr)"
check_exit "a failed pull-request run is refused even when main is green" 1 \
  run_gates "$PR_FAILED" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"
check_says "and says so" "pull request" \
  run_gates "$PR_FAILED" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"

# Absence is a pass — the shape that let 0.5.0 through — so it has to be said
# out loud rather than passed over in silence.
check_says "no pull-request run is announced, not silently skipped" "No pull-request run" \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"

# --- the environment gates ---------------------------------------------------

STALE_PREVIEW="$(health_for prod.test "0.5.1+$GOOD_COMMIT" 6)
$(health_for preview.test "0.5.0+ffffff0" 6)
$(health_for rehearsal.test "0.5.1+$GOOD_COMMIT" 6)"
check_exit "a preview on another commit is refused" 1 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$STALE_PREVIEW" "$GOOD_COMMIT"
check_says "and names both commits" "preview is running commit" \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$STALE_PREVIEW" "$GOOD_COMMIT"

STALE_REHEARSAL="$(health_for prod.test "0.5.1+$GOOD_COMMIT" 6)
$(health_for preview.test "0.5.1+$GOOD_COMMIT" 6)
$(health_for rehearsal.test "0.5.0+ffffff0" 6)"
check_exit "a rehearsal host on another commit is refused" 1 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$STALE_REHEARSAL" "$GOOD_COMMIT"

# --- the schema gate: physics, never skippable -------------------------------
#
# An image the database has outrun does not boot, so shipping it turns a bug
# into an outage. This is the one gate an emergency must not get past either.

AHEAD="$(health_for prod.test "0.5.1+$GOOD_COMMIT" 99)
$(health_for preview.test "0.5.1+$GOOD_COMMIT" 99)
$(health_for rehearsal.test "0.5.1+$GOOD_COMMIT" 99)"
check_exit "a database ahead of the image is refused" 1 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$AHEAD" "$GOOD_COMMIT"
check_exit "and an emergency cannot get past it either" 1 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$AHEAD" "$GOOD_COMMIT" DEPLOY_EMERGENCY=drill

# --- everything green --------------------------------------------------------

check_exit "every gate passing reaches the build" 0 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"
check_says "and says nothing was built" "stopping before anything is built" \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT"

# --- emergency ---------------------------------------------------------------
#
# It may skip the two gates that cost an image build, and nothing else.

check_exit "an emergency skips a stale preview and rehearsal" 0 \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$STALE_PREVIEW" "$GOOD_COMMIT" DEPLOY_EMERGENCY=drill
check_says "and says which gates it skipped" "Skipping the rehearsal gate (emergency)" \
  run_gates "$GREEN_MAIN" "$GREEN_JOBS" "$STALE_PREVIEW" "$GOOD_COMMIT" DEPLOY_EMERGENCY=drill

# The one that matters most: an emergency is not a way past a failing test.
check_exit "an emergency still requires CI" 1 \
  run_gates "$FOUR_RUNS" "$GREEN_JOBS" "$(all_current $BAD_COMMIT)" "$BAD_COMMIT" DEPLOY_EMERGENCY=drill
check_says "and still requires e2e to have run" "e2e" \
  run_gates "$GREEN_MAIN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT" DEPLOY_EMERGENCY=drill

# --- a rehearsal deploy asks a different question -----------------------------
#
# #100: it targets a commit that is usually still on a branch, so there is no
# push-to-main run, and e2e does not run on a branch push at all.

BRANCH_RUN="$(row 902 push some-branch completed success https://example/branch)"
check_exit "a rehearsal is judged by its own push run" 0 \
  run_gates "$BRANCH_RUN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT" \
  DEPLOY_ENV=rehearsal
check_says "and does not wait for main" "the 'push' run passed" \
  run_gates "$BRANCH_RUN" "$SKIPPED_E2E" "$(all_current $GOOD_COMMIT)" "$GOOD_COMMIT" \
  DEPLOY_ENV=rehearsal

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All deploy gate tests passed."
