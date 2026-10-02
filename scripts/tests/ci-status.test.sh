#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/ci-status.sh, under the same `set -euo pipefail` its callers
# run with.
#
# This is the gate `deploy.sh` trusts to say CI passed, and it has already
# failed open once in production: it passed the commit released as 0.5.0, whose
# only run that executed e2e had failed. Four runs existed for that commit and
# two of them were green, because a branch push and a tag push skip e2e
# entirely. Scanning them for any success found one.
#
# So the cases below are mostly about *which* run answers, and about the two
# conclusions that are not failures and are not passes either — `skipped` and
# `cancelled`, which between them were every conclusion e2e ever had for that
# commit.
#
# `gh` is replaced with a stub. It answers two calls: `gh run list` prints rows
# of runs, and `gh api .../jobs` prints rows of jobs. The stub does no
# filtering — that is the script's job, and the point of the test.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/ci-status.sh"
failures=0
TAB="$(printf '\t')"

# A scratch repo with one commit, and a `gh` on PATH printing `$1` for
# `run list` and `$2` for `api`.
run_with_gh() {
  local runs="$1" jobs="${2:-}"
  shift 2 2>/dev/null || shift $#
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "api" ]]; then'
    printf '  printf %s "%s"\n' "'%s\n'" "$jobs"
    echo 'else'
    printf '  printf %s "%s"\n' "'%s\n'" "$runs"
    echo 'fi'
  } > "$bin/gh"
  chmod +x "$bin/gh"

  git -C "$dir" init -q .
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" commit -q --allow-empty -m "a commit"

  ( cd "$dir" && PATH="$bin:$PATH" "$CHECK" "$@" 2>&1 )
  local status=$?
  rm -rf "$dir"
  return $status
}

# Same, with no `gh` reachable at all. PATH names every tool the script needs
# rather than trimming to /usr/bin — where `gh` lives on a CI runner, which is
# how this suite's sibling once passed locally and failed there.
run_without_gh() {
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"
  for tool in env bash git printf sleep awk cut; do
    src="$(command -v "$tool" || true)"
    [[ -n "$src" ]] && ln -s "$src" "$bin/$tool"
  done
  git -C "$dir" init -q .
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" commit -q --allow-empty -m "a commit"
  ( cd "$dir" && PATH="$bin" "$CHECK" --run push:main 2>&1 )
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
    echo "     got: $out"
    failures=$((failures + 1))
  fi
}

# id, event, headBranch, status, conclusion, url
row() { printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6"; }

# --- a gate must name its run -----------------------------------------------

check_exit "no --run is a usage error, not a permissive default" 2 \
  run_with_gh "$(row 1 push main completed success https://example/1)" ""
check_says "and says why" "must name the run" \
  run_with_gh "$(row 1 push main completed success https://example/1)" ""
check_exit "--run with no value is a usage error" 2 \
  run_with_gh "" "" --run

# --- the happy path ---------------------------------------------------------

check_exit "the named run passing is a pass" 0 \
  run_with_gh "$(row 1 push main completed success https://example/1)" "" --run push:main
check_says "and says which run it judged" "push on main" \
  run_with_gh "$(row 1 push main completed success https://example/1)" "" --run push:main

# An event with no branch given matches on the event alone.
check_exit "an event-only spec matches on the event" 0 \
  run_with_gh "$(row 1 pull_request some-branch completed success https://example/1)" "" \
  --run pull_request

# --- the failure this was written for ---------------------------------------
#
# The four runs for 3d821e9, in the order gh returns them (newest first). Two
# are green. The push to main — what a production deploy ships — was cancelled,
# and the pull request, the only run that executed e2e, failed.

FOUR_RUNS="$(row 31418814759 push prod-0.5.0 completed success https://example/tag)
$(row 31418632931 push main completed cancelled https://example/main)
$(row 31417859025 pull_request 0.5.0 completed failure https://example/pr)
$(row 31417856444 push 0.5.0 completed success https://example/branch)"

check_exit "a green run on another ref does not vouch for main" 1 \
  run_with_gh "$FOUR_RUNS" "" --run push:main
check_says "and it reports main's own conclusion" "cancelled" \
  run_with_gh "$FOUR_RUNS" "" --run push:main
# The specific regression: the old gate scanned for any success and found two.
check_says "the tag's success is not consulted" "push on main" \
  run_with_gh "$FOUR_RUNS" "" --run push:main
check_exit "the pull request's own run is judged on its own merits" 1 \
  run_with_gh "$FOUR_RUNS" "" --run pull_request

# --- cancelled and skipped are not passes -----------------------------------

check_says "a cancelled run advises a re-run, and names it" "gh run rerun 31418632931" \
  run_with_gh "$FOUR_RUNS" "" --run push:main

check_exit "a run still going is refused without --wait" 1 \
  run_with_gh "$(row 1 push main in_progress '' https://example/1)" "" --run push:main
check_says "and says it is still going" "still in_progress" \
  run_with_gh "$(row 1 push main in_progress '' https://example/1)" "" --run push:main

check_exit "no matching run is refused" 1 \
  run_with_gh "$(row 1 push some-branch completed success https://example/1)" "" --run push:main
check_says "and says none was found" "no 'push on main' run found" \
  run_with_gh "$(row 1 push some-branch completed success https://example/1)" "" --run push:main

check_exit "no runs at all is refused" 1 run_with_gh "" "" --run push:main

# gh failing is indistinguishable from no runs, and both must refuse — this is
# the fail-closed direction, and the one that matters.
check_exit "gh returning nothing is refused, not treated as success" 1 \
  run_with_gh "" "" --run push:main
check_exit "gh missing is refused" 1 run_without_gh
check_says "and says gh is missing" "not installed" run_without_gh

# --- a required job -----------------------------------------------------------
#
# A green run is not enough. A job whose `if` does not match is recorded as
# `skipped`, and a run of skipped jobs still concludes success — which is
# exactly how e2e was absent from three of the four runs above without any of
# them looking red.

GREEN_RUN="$(row 7 push main completed success https://example/7)"

check_exit "a required job that passed passes" 0 \
  run_with_gh "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}success" \
  --run push:main --require e2e
check_says "and says what it included" "including e2e" \
  run_with_gh "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}success" \
  --run push:main --require e2e

check_exit "a required job that was SKIPPED refuses a green run" 1 \
  run_with_gh "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}skipped" \
  --run push:main --require e2e
check_says "and names the conclusion" "skipped" \
  run_with_gh "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}skipped" \
  --run push:main --require e2e

# The rename trap: jobs are matched by display name because the API does not
# expose the workflow's job key. If someone renames the job in ci.yml, this
# must fail loudly rather than find nothing and shrug.
check_exit "a required job missing from the run is refused, not ignored" 1 \
  run_with_gh "$GREEN_RUN" "fmt · clippy · test · wasm${TAB}success" \
  --run push:main --require e2e
check_says "and points at the workflow file" "renamed" \
  run_with_gh "$GREEN_RUN" "fmt · clippy · test · wasm${TAB}success" \
  --run push:main --require e2e

check_exit "several required jobs all have to pass" 1 \
  run_with_gh "$GREEN_RUN" "fmt · clippy · test · wasm${TAB}success
e2e (Playwright · preview stack)${TAB}failure" \
  --run push:main --require fmt --require e2e

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All ci-status tests passed."
