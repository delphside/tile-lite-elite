#!/usr/bin/env bash
set -euo pipefail

# ci-status.sh — Did a *particular* CI run pass for a commit?
#
# Push is the one step of the release that has an *answer* rather than just
# an effect (docs/3.3, step 1.e), and this is how you get it. Relying on
# GitHub's failure emails instead has two problems: they only arrive when
# something breaks, so silence means "passed", "never started" and "went to
# spam" all at once; and they land somewhere other than where you are
# working.
#
# `deploy.sh` runs this as its CI gate, so the check you make by hand and
# the one the release enforces are the same code and cannot drift apart.
#
# **A gate names the run it depends on.** One commit has many runs — a branch
# push, a pull request, a push to main, a tag — and they do not run the same
# jobs. `e2e` only runs for a push to `main`, a pull request, or a manual
# dispatch; everywhere else it is recorded as `skipped`. So "did CI pass for
# this commit" has no single answer, and the version of this script that asked
# it passed the commit released as 0.5.0, whose only run that executed e2e had
# failed:
#
#     push          branch 0.5.0       e2e skipped     success
#     pull_request  branch 0.5.0       e2e FAILED      failure
#     push          branch main        e2e cancelled   cancelled
#     push          tag prod-0.5.0     e2e skipped     success
#
# Two successes in that list, and the gate found them. Hence `--run`: the
# caller says which run answers its question, and nothing else is consulted.
#
# Usage:
#   ./scripts/ci-status.sh --run push:main
#   ./scripts/ci-status.sh --run push:my-branch --wait
#   ./scripts/ci-status.sh --run push:main --require e2e <commit-ish>
#
#   --run <event>[:<branch>]  which run to judge. The newest matching one.
#                             Required — there is no "any run" mode, because
#                             that is the bug this script had.
#   --require <job-prefix>    a job that must be present and successful in
#                             that run. Repeatable. Guards the case where a
#                             job is `skipped` and the run is green anyway.
#   --wait                    block until that run finishes.
#
# Exits 0 only if the named run completed successfully for that exact commit.

WAIT=0
COMMITISH="HEAD"
RUN_SPEC=""
REQUIRED_JOBS=()

while (( $# > 0 )); do
  case "$1" in
    --wait) WAIT=1 ;;
    --run)
      shift
      [[ $# -gt 0 ]] || { echo "error: --run needs <event>[:<branch>]" >&2; exit 2; }
      RUN_SPEC="$1"
      ;;
    --require)
      shift
      [[ $# -gt 0 ]] || { echo "error: --require needs a job name" >&2; exit 2; }
      REQUIRED_JOBS+=("$1")
      ;;
    *) COMMITISH="$1" ;;
  esac
  shift
done

if [[ -z "$RUN_SPEC" ]]; then
  cat >&2 <<'USAGE'
error: --run is required.

A gate must name the run it depends on. One commit has several runs and they
do not run the same jobs, so "did CI pass" has no single answer — asking it
is what let a commit whose e2e had failed reach production.

  --run push:main           the push to main, what a production deploy ships
  --run push:<branch>       your branch's own run
  --run pull_request        the pull request's run

See docs/3.3, "Gating on a particular run".
USAGE
  exit 2
fi

RUN_EVENT="${RUN_SPEC%%:*}"
RUN_BRANCH=""
[[ "$RUN_SPEC" == *:* ]] && RUN_BRANCH="${RUN_SPEC#*:}"

if ! command -v gh > /dev/null; then
  echo "error: 'gh' is not installed — install it and run 'gh auth login'." >&2
  exit 1
fi

# `gh run list --commit` matches full hashes only; a short one silently
# returns nothing, which reads identically to "CI hasn't run".
FULL_SHA="$(git rev-parse "$COMMITISH")"
SHORT_SHA="$(git rev-parse --short "$COMMITISH")"

DESCRIBE="$RUN_EVENT${RUN_BRANCH:+ on $RUN_BRANCH}"

# CI takes 3-10 minutes; poll gently and give up well after the slowest run
# rather than hanging forever if a run is stuck or was never created.
POLL_SECONDS=10
MAX_ATTEMPTS=120   # 20 minutes

attempt=0
while true; do
  attempt=$((attempt + 1))

  # Every run for the commit, flattened. The selection is done here rather than
  # in the `--jq` expression so that it is this script's logic, testable with a
  # stub that only has to print rows — and so the suite does not depend on `jq`
  # being installed, which is the kind of assumption that has passed locally
  # and failed on a runner before.
  RUNS="$(gh run list --commit "$FULL_SHA" --workflow CI --limit 30 \
    --json databaseId,event,headBranch,status,conclusion,url \
    --jq '.[] | [.databaseId, .event, .headBranch, .status, .conclusion, .url] | @tsv' \
    2>/dev/null || true)"

  # The newest matching run, and only that one. `gh run list` returns newest
  # first, so the first match is the newest — which is what a re-run makes
  # current.
  MATCH="$(printf '%s\n' "$RUNS" | awk -F'\t' -v want_event="$RUN_EVENT" -v want_branch="$RUN_BRANCH" \
    '$2 == want_event && (want_branch == "" || $3 == want_branch) { print; exit }' || true)"

  RUN_ID="$(printf '%s' "$MATCH" | cut -f1)"
  STATUS="$(printf '%s' "$MATCH" | cut -f4)"
  CONCLUSION="$(printf '%s' "$MATCH" | cut -f5)"
  URL="$(printf '%s' "$MATCH" | cut -f6)"

  # Finished, whatever the verdict — judge it below.
  [[ -n "$MATCH" && "$STATUS" == "completed" ]] && break

  if (( WAIT == 0 )); then
    if [[ -z "$MATCH" ]]; then
      echo "CI: no '$DESCRIBE' run found for $SHORT_SHA." >&2
      echo "    Has the push landed? GitHub may not have started it yet." >&2
    else
      echo "CI: the '$DESCRIBE' run for $SHORT_SHA is still $STATUS." >&2
      [[ -n "$URL" ]] && echo "    $URL" >&2
    fi
    exit 1
  fi

  if (( attempt >= MAX_ATTEMPTS )); then
    echo "CI: gave up waiting for the '$DESCRIBE' run for $SHORT_SHA after $(( MAX_ATTEMPTS * POLL_SECONDS / 60 )) minutes (last seen: ${STATUS:-no run})." >&2
    [[ -n "$URL" ]] && echo "    $URL" >&2
    exit 1
  fi

  if (( attempt == 1 )); then
    echo "CI: waiting for the '$DESCRIBE' run for $SHORT_SHA${STATUS:+ ($STATUS)}..."
  fi
  sleep "$POLL_SECONDS"
done

if [[ "$CONCLUSION" != "success" ]]; then
  echo "CI: the '$DESCRIBE' run for $SHORT_SHA concluded '$CONCLUSION', not success." >&2
  [[ -n "$URL" ]] && echo "    $URL" >&2
  if [[ "$CONCLUSION" == "cancelled" ]]; then
    # Almost always `cancel-in-progress` stopping a run a newer push
    # superseded. The commit was never judged, so the gate cannot pass it —
    # but re-running is the fix, not a new commit. `main` is exempt from that
    # cancellation for exactly this reason; a run cancelled here is either an
    # older branch or somebody pressing the button.
    echo "    A cancelled run usually means a newer push superseded it, not that" >&2
    echo "    anything broke. Judge this commit on its own by re-running it:" >&2
    echo "      gh run rerun $RUN_ID" >&2
    echo "    then re-run this check." >&2
  else
    echo "    Fix it and commit again — the release gate will refuse this commit." >&2
  fi
  exit 1
fi

# A green run is not enough on its own: a job whose `if` does not match is
# recorded as `skipped`, and a run of skipped jobs still concludes success.
# That is how e2e was absent from three of the four runs for 0.5.0 without
# any of them looking red.
JOBS=""
if (( ${#REQUIRED_JOBS[@]} > 0 )); then
  JOBS="$(gh api "repos/{owner}/{repo}/actions/runs/$RUN_ID/jobs" \
    --jq '.jobs[] | [.name, .conclusion] | @tsv' 2>/dev/null || true)"
fi

for job in "${REQUIRED_JOBS[@]}"; do
  # Prefix match: the API gives display names ("e2e (Playwright · preview
  # stack)"), not the workflow's job key, so a gate names the readable start of
  # one. A rename in ci.yml then fails here rather than quietly excusing a job.
  JOB_CONCLUSION="$(printf '%s\n' "$JOBS" | awk -F'\t' -v want="$job" \
    'index($1, want) == 1 { print $2; exit }' || true)"
  if [[ -z "$JOB_CONCLUSION" ]]; then
    echo "CI: the '$DESCRIBE' run for $SHORT_SHA has no job starting '$job'." >&2
    echo "    Either it was renamed in .github/workflows/ci.yml, or it did not run." >&2
    [[ -n "$URL" ]] && echo "    $URL" >&2
    exit 1
  fi
  if [[ "$JOB_CONCLUSION" != "success" ]]; then
    echo "CI: job '$job' in the '$DESCRIBE' run for $SHORT_SHA concluded '$JOB_CONCLUSION', not success." >&2
    [[ -n "$URL" ]] && echo "    $URL" >&2
    exit 1
  fi
done

echo "CI: the '$DESCRIBE' run passed for $SHORT_SHA${REQUIRED_JOBS[*]:+ (including ${REQUIRED_JOBS[*]})}"
exit 0
