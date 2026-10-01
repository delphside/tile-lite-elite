#!/usr/bin/env bats

# ci-status.sh, the gate deploy.sh trusts to say CI passed. It has failed open
# once in production: it passed the commit released as 0.5.0, whose only run
# that executed e2e had failed. Four runs existed for that commit and two were
# green, because a branch push and a tag push skip e2e entirely, and scanning
# them for any success found one.
#
# So the cases are mostly about which run answers, and about the two
# conclusions that are neither failures nor passes, `skipped` and `cancelled`,
# which between them were every conclusion e2e ever had for that commit.
#
# gh is a stub answering two calls: `gh run list` prints rows of runs, and
# `gh api .../jobs` prints rows of jobs. It does no filtering; that is the
# script's job, and the point of the test.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  CHECK="$BATS_TEST_DIRNAME/../application/deliver/ci-status.sh"
  D="$BATS_TEST_TMPDIR"
  git init -q "$D/repo"
  git -C "$D/repo" config user.email t@example.com
  git -C "$D/repo" config user.name Test
  git -C "$D/repo" commit -q --allow-empty -m "a commit"
  mkdir -p "$D/bin"
}

# ci <runs> <jobs> [args...]: the check, with a gh printing <runs> for
# `run list` and <jobs> for `api`.
ci() {
  printf '%s\n' "$1" > "$D/runs"; printf '%s\n' "$2" > "$D/jobs"
  printf '#!/usr/bin/env bash\nif [[ "$1" == api ]]; then cat "%s/jobs"; else cat "%s/runs"; fi\n' "$D" "$D" > "$D/bin/gh"
  chmod +x "$D/bin/gh"
  run bash -c 'cd "$1" && PATH="$2:$PATH" "${@:3}"' _ "$D/repo" "$D/bin" "$CHECK" "${@:3}"
}

# id, event, headBranch, status, conclusion, url
row() { printf '%s\t%s\t%s\t%s\t%s\t%s' "$@"; }

# The four runs for 3d821e9, newest first as gh returns them. Two are green. The
# push to main, what a production deploy ships, was cancelled, and the pull
# request, the only run that executed e2e, failed.
FOUR_RUNS="$(row 31418814759 push prod-0.5.0 completed success https://example/tag)
$(row 31418632931 push main completed cancelled https://example/main)
$(row 31417859025 pull_request 0.5.0 completed failure https://example/pr)
$(row 31417856444 push 0.5.0 completed success https://example/branch)"
GREEN_RUN="$(row 7 push main completed success https://example/7)"
TAB=$'\t'

@test "no --run is a usage error, not a permissive default, and says why" {
  ci "$(row 1 push main completed success https://example/1)" ""
  assert_equal "$status" 2
  assert_output --partial "must name the run"
}

@test "--run with no value is a usage error" {
  ci "" "" --run
  assert_equal "$status" 2
}

@test "the named run passing is a pass, and it says which run it judged" {
  ci "$(row 1 push main completed success https://example/1)" "" --run push:main
  assert_success
  assert_output --partial "push on main"
}

@test "an event-only spec matches on the event" {
  ci "$(row 1 pull_request some-branch completed success https://example/1)" "" --run pull_request
  assert_success
}

# The failure this was written for: the old gate scanned for any success and
# found two.
@test "a green run on another ref does not vouch for main" {
  ci "$FOUR_RUNS" "" --run push:main
  assert_equal "$status" 1
  assert_output --partial "cancelled"
  assert_output --partial "push on main"
}

@test "the pull request's own run is judged on its own merits" {
  ci "$FOUR_RUNS" "" --run pull_request
  assert_equal "$status" 1
}

@test "a cancelled run advises a re-run, and names it" {
  ci "$FOUR_RUNS" "" --run push:main
  assert_output --partial "gh run rerun 31418632931"
}

@test "a run still going is refused without --wait, and says so" {
  ci "$(row 1 push main in_progress '' https://example/1)" "" --run push:main
  assert_equal "$status" 1
  assert_output --partial "still in_progress"
}

@test "no matching run is refused, and says none was found" {
  ci "$(row 1 push some-branch completed success https://example/1)" "" --run push:main
  assert_equal "$status" 1
  assert_output --partial "no 'push on main' run found"
}

# gh failing is indistinguishable from no runs, and both must refuse: the
# fail-closed direction, and the one that matters.
@test "no runs at all, or gh returning nothing, is refused, not treated as success" {
  ci "" "" --run push:main
  assert_equal "$status" 1
}

# PATH names every tool the script needs rather than trimming to /usr/bin,
# where gh lives on a CI runner: how a sibling suite once passed locally and
# failed there.
@test "gh missing is refused, and says gh is not installed" {
  local tool src
  mkdir -p "$D/bare"
  for tool in env bash git printf sleep awk cut; do
    src="$(command -v "$tool" || true)"
    [[ -n "$src" ]] && ln -s "$src" "$D/bare/$tool"
  done
  run bash -c 'cd "$1" && PATH="$2" "$3" --run push:main' _ "$D/repo" "$D/bare" "$CHECK"
  assert_equal "$status" 1
  assert_output --partial "not installed"
}

# A green run is not enough. A job whose `if` does not match is recorded as
# skipped, and a run of skipped jobs still concludes success: exactly how e2e
# was absent from three of the four runs above without any of them looking red.
@test "a required job that passed passes, and says what it included" {
  ci "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}success" --run push:main --require e2e
  assert_success
  assert_output --partial "including e2e"
}

@test "a required job that was skipped refuses a green run, naming the conclusion" {
  ci "$GREEN_RUN" "e2e (Playwright · preview stack)${TAB}skipped" --run push:main --require e2e
  assert_equal "$status" 1
  assert_output --partial "skipped"
}

# Jobs are matched by display name because the API does not expose the
# workflow's job key. If the job is renamed in ci.yml this must fail loudly
# rather than find nothing and shrug.
@test "a required job missing from the run is refused, pointing at the workflow" {
  ci "$GREEN_RUN" "fmt · clippy · test · wasm${TAB}success" --run push:main --require e2e
  assert_equal "$status" 1
  assert_output --partial "renamed"
}

@test "several required jobs all have to pass" {
  ci "$GREEN_RUN" "fmt · clippy · test · wasm${TAB}success
e2e (Playwright · preview stack)${TAB}failure" --run push:main --require fmt --require e2e
  assert_equal "$status" 1
}
