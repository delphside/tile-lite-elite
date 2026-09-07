#!/usr/bin/env bash
set -euo pipefail

# merge-to-release.sh — merge a project's pull request into a release branch,
# but only when CI has actually answered for it. #344 R4, R5, from #144.
#
# **Deploy is the last responsible moment; merge is the cheapest one.** The
# change is still in one person's head and nothing has been built on top. The
# e2e job went red on `0cc012e` and `ea8ff8e` was merged over it two days later
# without anybody noticing, because a branch's own push runs are green when e2e
# **did not run**, not because it passed.
#
# **The check is here rather than in a hook** because a push happens for reasons
# other than merging, and a gate that fires on the wrong occasions is one people
# learn to bypass. Doing the merge *through* this keeps the check attached to
# the act it is about.
#
# **Two questions, and the second is the one that gets forgotten:**
#
#   1. the pull request's own run is green — that is the run which exercises
#      e2e for a branch;
#   2. the release branch's **current tip** is green — otherwise a good change
#      is merged onto rubble and inherits the blame.
#
# No pull request's run ever tests the combination: it tests its branch against
# its base at that moment. So (2) is not paranoia, it is the only thing standing
# between "each part was fine" and "the whole is fine".
#
# Both are asked through `ci-status.sh`, so this gate and `deploy.sh`'s cannot
# answer differently — the defect that made #144 worth raising existed twice
# for want of one copy.
#
# Usage:
#   ./scripts/merge-to-release.sh <pr-number>
#   ./scripts/merge-to-release.sh <pr-number> --check-only
#   ./scripts/merge-to-release.sh <pr-number> --allow-missing-run
#
# Exits 0 on a completed merge (or a passing --check-only), 1 on a refusal,
# 2 on a usage error.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NWO="${REPO_NWO:-delphside/tile-lite-elite}"
CI_STATUS="${CI_STATUS:-$HERE/ci-status.sh}"

PR=""
CHECK_ONLY=0
ALLOW_MISSING=0

while (( $# > 0 )); do
  case "$1" in
    --check-only)        CHECK_ONLY=1 ;;
    --allow-missing-run) ALLOW_MISSING=1 ;;
    -h|--help) sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *)  [[ -z "$PR" ]] || { echo "error: one pull request at a time" >&2; exit 2; }
        PR="$1" ;;
  esac
  shift
done

[[ -n "$PR" ]] || { echo "usage: merge-to-release.sh <pr-number> [--check-only] [--allow-missing-run]" >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "error: '$PR' is not a pull request number" >&2; exit 2; }

# One call for everything about the pull request. Asking separately invites the
# two answers to describe different moments.
PR_JSON="$(gh pr view "$PR" -R "$REPO_NWO" \
  --json number,headRefName,headRefOid,baseRefName,state,isDraft 2>/dev/null || true)"
[[ -n "$PR_JSON" ]] || { echo "error: cannot read pull request #$PR from $REPO_NWO" >&2; exit 1; }

HEAD_REF="$(printf '%s' "$PR_JSON" | jq -r .headRefName)"
HEAD_SHA="$(printf '%s' "$PR_JSON" | jq -r .headRefOid)"
BASE_REF="$(printf '%s' "$PR_JSON" | jq -r .baseRefName)"
PR_STATE="$(printf '%s' "$PR_JSON" | jq -r .state)"
IS_DRAFT="$(printf '%s' "$PR_JSON" | jq -r .isDraft)"

echo "==> #$PR: $HEAD_REF -> $BASE_REF ($(printf '%s' "$HEAD_SHA" | cut -c1-7))"

[[ "$PR_STATE" == "OPEN" ]] || { echo "error: #$PR is $PR_STATE, not OPEN." >&2; exit 1; }
[[ "$IS_DRAFT" == "false" ]] || { echo "error: #$PR is a draft. Mark it ready first." >&2; exit 1; }

# **This script is only for release branches.** Merging into `main` goes through
# the ordinary path, where `deploy.sh`'s gate is the backstop; there is no
# release branch tip to be red, so the second question would have no meaning.
if [[ "$BASE_REF" != release/* ]]; then
  echo "error: #$PR targets '$BASE_REF', which is not a release branch." >&2
  echo "       This script exists for merges into release/*, where the tip's own" >&2
  echo "       run is what the next merge is judged against. Use the ordinary path." >&2
  exit 1
fi

# The release branch's tip *as GitHub has it*, not as this checkout has it. The
# merge happens on GitHub, so the tip that matters is GitHub's.
BASE_SHA="$(gh api "repos/$REPO_NWO/git/ref/heads/$BASE_REF" --jq .object.sha 2>/dev/null || true)"
[[ -n "$BASE_SHA" ]] || { echo "error: cannot read the tip of $BASE_REF" >&2; exit 1; }

# Absence is announced, never swallowed. "No run found" reading as success is
# the exact shape that let 0.5.0 through — `deploy.sh` says it out loud for the
# same reason. Here it also **refuses**, because a merge is cheap to retry and a
# release branch with an unjudged commit on it is not.
run_present() {  # $1 = event[:branch], $2 = sha
  local spec="$1" sha="$2" event="${1%%:*}" branch=""
  [[ "$spec" == *:* ]] && branch="${spec#*:}"
  gh run list -R "$REPO_NWO" --commit "$sha" --workflow CI --limit 30 \
    --json event,headBranch --jq '.[] | [.event, .headBranch] | @tsv' 2>/dev/null \
    | awk -F'\t' -v e="$event" -v b="$branch" \
        'b == "" ? $1 == e : ($1 == e && $2 == b) { found = 1 } END { exit !found }'
}

judge() {  # $1 = what, $2 = run spec, $3 = sha
  local what="$1" spec="$2" sha="$3"
  if ! run_present "$spec" "$sha"; then
    echo "==> No '$spec' run for $what ($(printf '%s' "$sha" | cut -c1-7)) — nothing to check there"
    if (( ALLOW_MISSING )); then
      echo "    continuing anyway (--allow-missing-run)"
      return 0
    fi
    echo "error: refusing — a missing run is not a passing one." >&2
    echo "       --allow-missing-run if you have decided it is genuinely absent." >&2
    return 1
  fi
  if ! "$CI_STATUS" --run "$spec" --require e2e "$sha"; then
    echo "error: refusing — $what did not pass CI." >&2
    return 1
  fi
  echo "==> $what: '$spec' passed, with e2e"
}

judge "the pull request" "pull_request" "$HEAD_SHA"
judge "the tip of $BASE_REF" "push:$BASE_REF" "$BASE_SHA"

if (( CHECK_ONLY )); then
  echo "==> Both checks passed. Not merging (--check-only)."
  exit 0
fi

# Rebase, not fast-forward. The byte-for-byte guarantee belongs to the *release
# branch's* merge into `main` (#344 R8) — here the tip is going to be rehearsed
# afterwards anyway, so a linear history is worth more than a preserved SHA.
echo "==> Merging #$PR into $BASE_REF"
gh pr merge "$PR" -R "$REPO_NWO" --rebase --delete-branch
echo "==> Merged. $BASE_REF now has a new tip — its run is what the next merge is judged against."
