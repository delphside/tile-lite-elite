#!/usr/bin/env bash
set -euo pipefail

# status.sh — Where every open change currently is, in one screen.
#
# **This is a view, not a tracking system.** It stores nothing and records
# nothing. Every column is derived from something that is already true:
#
#   is the work done          issue open/closed
#   is it in production       milestone open/closed
#   is it being worked on     a `Refs #N` commit exists off origin/main
#   merged, awaiting release  a `Refs #N` commit is on origin/main
#   what type of change       the issue's type label (docs/3.3, "The six types")
#   what is live right now    GET /health
#
# Because nothing is stored, nothing can drift and there is nothing to keep
# up to date — which is the whole reason to derive status rather than record
# it.
#
# The two "is it being worked on" rows are the same question asked of the same
# evidence, `Refs #N`, split only by whether the commit has landed. Reading the
# commits rather than the branch name is what lets one branch carry several
# issues and show under each — the shape most real changes turn out to have.
# The branch-name glob survives as a fallback for a branch with no commits yet.
#
# The cost of deriving rather than recording is that the view is only as good
# as the convention: a change with neither a `Refs #N` trailer nor an
# `issue-<N>-*` branch still reads "not started". That is deliberate. A view
# that papered over a missing trailer would remove the one signal that the
# convention had slipped.
#
# Usage:
#   ./scripts/status.sh            # open changes + what production is running
#   ./scripts/status.sh --fetch    # `git fetch` first, for accurate ancestry
#
# Needs `gh` authenticated (same as deploy.sh's milestone handling).

PROD_URL="${PROD_URL:-https://tileliteelite.com}"
# The rehearsal host comes from the file that defines it, not a second copy —
# rehearsal-target.sh's own comment is the reason: two definitions eventually
# disagree, and the one that disagrees silently points somewhere wrong.
#
# Read in a *subshell* regardless: that file exports variables meant for
# deploy.sh, and this script only wants one value out of it. Before #24 the
# variable was called PROD_URL, and sourcing it directly overwrote
# production's URL with the rehearsal one — this script reported the
# rehearsal host on both lines, which looked plausible because they are
# usually on the same commit.
REHEARSAL_URL="${REHEARSAL_URL:-$(
  . "$(cd "$(dirname "$0")" && pwd)/rehearsal-target.sh" > /dev/null 2>&1
  printf '%s' "$TARGET_URL"
)}"
# `STAGING_URL` honoured as a fallback, as deploy.sh does: preview is what
# used to be called staging before #22 renamed the files.
PREVIEW_URL="${PREVIEW_URL:-${STAGING_URL:-http://localhost:8081}}"

if [[ "${1:-}" == "--fetch" ]]; then
  echo "==> Fetching"
  git fetch --quiet origin
fi

if ! command -v gh > /dev/null 2>&1; then
  echo "error: needs the GitHub CLI (gh) on PATH and authenticated." >&2
  exit 1
fi

# Every `grep` below is guarded with `|| true`. Under `set -o pipefail` a
# grep that matches nothing exits 1, and inside a command substitution that
# status propagates out and kills the assignment — which is how a silent
# abort once reached a production deploy (docs/3.3, "Rolling back").
version_of() {
  curl -sf --max-time 5 "$1/health" 2>/dev/null \
    | grep -o '"app_version":"[^"]*"' 2>/dev/null | cut -d'"' -f4 || true
}

# How far behind `main` an environment is, in commits. Answers "is this stale,
# and by how much" without having to compare two hashes by eye. `--` guards a
# build id that is not a commit this checkout knows.
behind_main() {
  local version="$1" sha
  sha="${version#*+}"
  [[ -z "$version" || "$sha" == "$version" ]] && { echo ""; return; }
  git rev-parse -q --verify "$sha^{commit}" > /dev/null 2>&1 || { echo "unknown commit"; return; }
  # Changes, not commits. A merge commit is not a change — it is bookkeeping
  # about how changes arrived — and counting it made this line disagree with
  # the release preview below, which has always used `--no-merges`. Two numbers
  # for the same range, a few rows apart: 16 against 9, and no way to tell from
  # the report which was wrong.
  #
  # The merges are still shown rather than hidden, so somebody comparing this
  # against `git log` finds their own number here instead of a third one.
  local changes merges
  changes="$(git rev-list --count --no-merges "$sha..origin/main" 2>/dev/null || true)"
  merges="$(git rev-list --count --merges "$sha..origin/main" 2>/dev/null || true)"
  local suffix=""
  [[ -n "$merges" && "$merges" != "0" ]] && suffix=" (+$merges merges)"
  case "$changes" in
    "" ) echo "" ;;
    0  ) echo "up to date with main$suffix" ;;
    1  ) echo "1 change behind main$suffix" ;;
    *  ) echo "$changes changes behind main$suffix" ;;
  esac
}

echo "==> Environments"
PROD_V="$(version_of "$PROD_URL")"
REHEARSAL_V="$(version_of "$REHEARSAL_URL")"
PREVIEW_V="$(version_of "$PREVIEW_URL")"
printf '    %-12s %-18s %-36s %s\n' "production" "${PROD_V:-unreachable}" "$(behind_main "$PROD_V")" "what users have"
printf '    %-12s %-18s %-36s %s\n' "rehearsal" "${REHEARSAL_V:-not running}" "$(behind_main "$REHEARSAL_V")" "what the release gate checks"
printf '    %-12s %-18s %-36s %s\n' "preview" "${PREVIEW_V:-not running}" "$(behind_main "$PREVIEW_V")" "what you last looked at"
echo

# What a release from `main` would put out, right now.
#
# `Open changes` below answers "where is each change"; this answers the other
# question, which is the one asked immediately before deciding to ship: *what
# am I about to release, and is it the right kind of version?* Scanning thirty
# rows for "merged, awaiting release" is not the same thing, and it misses the
# commits that carry no issue at all — docs, tooling, the version bump — which
# is most of what usually sits in main.
# Does a change of this type reach users when a release ships, or was it live
# the moment it merged?
#
# One rule, used by both the release preview and the "done, not yet released"
# list below. They used to answer differently: this section knew that
# documentation and tooling are live at merge, and that section did not, so
# every merge-lane change ever closed accumulated there for good — nine of them
# by the time anyone counted, all of them already live.
reach_of() {
  case "$1" in
    *documentation*|*non-prod-tooling*) echo "live at merge" ;;
    *prod-tooling*)                     echo "live at merge, unless it is admin-cli" ;;
    *)                                  echo "reaches users" ;;
  esac
}

# Non-empty if this issue was delivered by a release that has already happened
# — its milestone is a version, and that version is tagged. Version milestones
# are closed by `deploy.sh` as it ships them, so "closed and named like a
# version" is the same fact read two ways; the tag is the one that cannot be
# closed by hand.
shipped_already() {
  local milestone
  milestone="$(gh issue view "$1" --json milestone --jq '.milestone.title // ""' 2>/dev/null || true)"
  [[ "$milestone" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo ""; return; }
  if git rev-parse -q --verify "refs/tags/prod-$milestone" > /dev/null 2>&1; then
    echo "already shipped in $milestone"
  else
    echo ""
  fi
}

echo "==> A release from main would ship"
MAIN_VERSION="$(git show origin/main:Cargo.toml 2>/dev/null | grep -m1 '^version' | cut -d'"' -f2 || true)"
LAST_PROD_TAG="$(git tag --list 'prod-[0-9]*' 2>/dev/null \
  | sed 's/^prod-//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"

# What to measure from: the commit production is *running*, not the newest tag.
#
# They agree almost always, and disagree exactly when it matters. `rollback.sh`
# puts production back to the previous images without moving any tag —
# correctly, since the tag records a release that did happen — so after a
# rollback the newest tag is ahead of what is live. Measuring from the tag then
# omits everything between them, including the change that was rolled back,
# which is the one somebody is most likely to be asking about.
#
# `/health` is already read above for the Environments block, so this costs
# nothing. Falls back to the tag when production cannot be reached, or reports
# a commit this checkout does not have — and says which it used either way,
# because silently answering a different question is the fault being fixed.
PROD_SHA="${PROD_V#*+}"
BASE_REF=""
BASE_NOTE=""
PROD_VERSION="$LAST_PROD_TAG"
if [[ -n "$PROD_V" && "$PROD_SHA" != "$PROD_V" ]] \
  && git rev-parse -q --verify "$PROD_SHA^{commit}" > /dev/null 2>&1; then
  BASE_REF="$PROD_SHA"
  PROD_VERSION="${PROD_V%%+*}"
elif [[ -n "$LAST_PROD_TAG" ]]; then
  BASE_REF="prod-$LAST_PROD_TAG"
  BASE_NOTE="  (from the newest tag — production did not answer)"
fi

if [[ -z "$BASE_REF" ]]; then
  printf '    %s\n' "nothing to compare against: production did not answer and there is no prod-* tag"
else
  RANGE="$BASE_REF..origin/main"
  COMMIT_COUNT="$(git rev-list --count --no-merges "$RANGE" 2>/dev/null || echo 0)"
  printf '    %-12s %s\n' "version" "$MAIN_VERSION  (production has $PROD_VERSION)$BASE_NOTE"
  MERGE_COUNT="$(git rev-list --count --merges "$RANGE" 2>/dev/null || echo 0)"
  printf '    %-12s %s\n' "changes" \
    "$COMMIT_COUNT on main since $BASE_REF$( [[ "$MERGE_COUNT" != "0" ]] && printf ' (+%s merges)' "$MERGE_COUNT" )"

  # Issues referenced by those commits, in the order they were merged.
  SHIPPING="$(git log "$RANGE" --no-merges -E --format=%s 2>/dev/null \
    | grep -oE 'Refs #[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | sort -un || true)"
  # `Refs` lives in the body as often as the subject, so look there too.
  SHIPPING="$(printf '%s\n%s' "$SHIPPING" "$(git log "$RANGE" --no-merges --format=%b 2>/dev/null \
    | grep -oE 'Refs #[0-9]+' 2>/dev/null | grep -oE '[0-9]+' || true)" | sort -un | grep . || true)"

  if [[ -z "$SHIPPING" ]]; then
    printf '    %-12s %s\n' "issues" "none — nothing on main references an issue"
  else
    FUNCTIONAL=""
    while read -r num; do
      [[ -z "$num" ]] && continue
      meta="$(gh issue view "$num" --json title,labels \
        --jq '"\(.title)\t\([.labels[].name] | join(","))"' 2>/dev/null || true)"
      title="${meta%%$'\t'*}"
      labels="${meta#*$'\t'}"
      [[ -z "$meta" ]] && { title="(could not read issue)"; labels=""; }
      reach="$(reach_of "$labels")"
      # A change already delivered by an earlier release can still be
      # referenced by later commits — its design note being retired, say. It is
      # not part of what this release delivers, and counting it produced a
      # "functional change in a patch bump" warning for a release that carried
      # no functionality at all.
      already="$(shipped_already "$num")"
      printf '    %-12s #%-4s %-40s %-16s %s\n' \
        "ships" "$num" "$(printf '%.40s' "$title")" "$labels" "${already:-$reach}"
      if [[ -z "$already" && "$reach" == "reaches users" ]]; then
        case "$labels" in *major-function*|*minor-function*) FUNCTIONAL="yes" ;; esac
      fi
    done <<< "$SHIPPING"

    # The same judgement check-release-version.sh makes at deploy time, made
    # here instead — before the work of a preview and a rehearsal, rather than
    # after it.
    if [[ -n "$FUNCTIONAL" && "${MAIN_VERSION%.*}" == "${PROD_VERSION%.*}" ]]; then
      printf '    %-12s %s\n' "warning" "functional change in a patch bump — see docs/3.3, \"Releases are branches\""
    fi
  fi
fi
echo

# The branch for an issue, preferring a local one (that is what you are
# working in) over its remote copy. Printed in the "in progress" line so a
# mis-named or forgotten branch is visible rather than merely absent.
branch_for_issue() {
  git branch --list "issue-$1-*" --format='%(refname:short)' 2>/dev/null | head -1 \
    || true
}
remote_branch_for_issue() {
  git branch --remotes --list "origin/issue-$1-*" --format='%(refname:short)' 2>/dev/null \
    | head -1 || true
}

# The branch carrying unmerged work for an issue, found by its commits rather
# than by its name — so a branch covering two issues is visible under both, and
# an issue keeps its own state whatever the branch is called.
#
# `--not origin/main` is the whole trick: it asks for work that has *not*
# landed, which is what "in progress" means. Without it an old `Refs #N` on
# main masks every later commit for the same issue, which is how #41 read
# "merged, awaiting release" while its second round was still being written.
unmerged_branch_for_issue() {
  local num="$1" sha
  sha="$(git log --branches --remotes --not origin/main \
    -E --grep="Refs #${num}([^0-9]|\$)" --format=%h -1 2>/dev/null || true)"
  [[ -z "$sha" ]] && { echo ""; return; }
  local local_branch
  local_branch="$(git branch --contains "$sha" --format='%(refname:short)' 2>/dev/null \
    | head -1 || true)"
  if [[ -n "$local_branch" ]]; then
    echo "$local_branch"
  else
    git branch --remotes --contains "$sha" --format='%(refname:short)' 2>/dev/null \
      | grep -v HEAD | head -1 | sed 's|^origin/||' || true
  fi
}

state_of_issue() {
  local num="$1" type="${2:-}" branch unmerged
  branch="$(branch_for_issue "$num")"
  [[ -z "$branch" ]] && branch="$(remote_branch_for_issue "$num")"

  # Unmerged work first, because it is the more current fact. An issue that has
  # been merged once and reopened, or one sharing a branch with another, is
  # still in progress — and asking main first said otherwise.
  unmerged="$(unmerged_branch_for_issue "$num")"
  if [[ -n "$unmerged" ]]; then
    echo "in progress ($unmerged)"
    return
  fi

  # Then main's history. A merged change has its branch deleted, so
  # branch-only detection reported finished work as "not started" — which it
  # did for three issues the moment they were merged. `Refs #N` is in every
  # commit by convention, and unlike a branch it is permanent. The trailing
  # guard stops #1 matching "Refs #19".
  if git log origin/main -E --grep="Refs #${num}([^0-9]|\$)" \
       --format=%h 2>/dev/null | grep -q .; then
    # Only the types that change the app wait for a release. Documentation
    # and non-production tooling are finished at merge, so say so as an
    # action rather than leaving them looking blocked on something.
    case "$type" in
      documentation)    echo "merged — close it" ;;
      non-prod-tooling) echo "merged — smoke-test, then close" ;;
      *)                echo "merged, awaiting release" ;;
    esac
    return
  fi

  if [[ -z "$branch" ]]; then
    echo "not started"
    return
  fi
  # A branch that is still exactly origin/main carries no commits yet, so it
  # is an ancestor trivially. Checking that first stops a branch created
  # seconds ago from reporting itself as merged — which it did, on the very
  # branch this script was written on.
  if [[ "$(git rev-parse "$branch" 2>/dev/null)" == "$(git rev-parse origin/main 2>/dev/null)" ]]; then
    echo "branched, no commits ($branch)"
  # A branch whose commits are all in main but which carries no `Refs #N`
  # — an older change, or one whose trailer was forgotten.
  elif git merge-base --is-ancestor "$branch" origin/main 2>/dev/null; then
    echo "merged (no Refs trailer)"
  else
    echo "in progress ($branch)"
  fi
}

# One type label per issue — see docs/3.3, "The six types of change". An
# issue with none reads "unclassified", which is the point: the gap is a
# prompt to classify it, not something to paper over with a default.
type_of() {
  case "$1" in
    *documentation*)    echo "documentation" ;;
    # `non-prod-tooling` must be tested before `prod-tooling`: the second
    # pattern is a substring of the first, so the wrong order would report
    # every non-production change as production tooling.
    *non-prod-tooling*) echo "non-prod-tooling" ;;
    *prod-tooling*)     echo "prod-tooling" ;;
    *major-function*)   echo "major-function" ;;
    *minor-function*)   echo "minor-function" ;;
    *bug*)              echo "defect fix" ;;
    *appearance*)       echo "appearance" ;;
    *)                  echo "unclassified" ;;
  esac
}

# Width available for the title: whatever the terminal has left after the
# fixed columns. Titles were cut at 40 characters with no ellipsis, so a
# truncated one read as a complete one — "DTO conversion belongs at the
# boundary," looked like the whole issue.
#
# 22 covers the number and type columns and their gaps; 30 leaves room for
# the longest state ("merged — smoke-test, then close"). Falls back to 100
# columns when there is no terminal, so piping to a file stays readable.
TERM_COLS="${COLUMNS:-$(tput cols 2> /dev/null || echo 100)}"
TITLE_WIDTH=$((TERM_COLS - 22 - 30))
(( TITLE_WIDTH < 30 )) && TITLE_WIDTH=30

# Cut to fit and pad to the column, with a trailing ellipsis only when
# something was actually cut.
#
# Padded here rather than with printf's `%-Ns`, which pads to a width in
# *bytes* while `${#title}` counts *characters*. An em-dash is 3 bytes and one
# display column, so every one in a title cost two spaces of padding and the
# columns after it drifted left. The ellipsis is multi-byte too, so truncated
# rows drifted as well.
fit_title() {
  local title="$1"
  if (( ${#title} > TITLE_WIDTH )); then
    title="${title:0:$((TITLE_WIDTH - 1))}…"
  fi
  local padding=$(( TITLE_WIDTH - ${#title} ))
  printf '%s' "$title"
  (( padding > 0 )) && printf '%*s' "$padding" ''
  return 0
}

# Which documents are overdue a read.
#
# Not the same question as 4.x's freshness stamp, which asks whether a document
# still matches the code. This asks whether it is still worth reading: relevant,
# ordered, navigable — which only reading the whole thing can answer, and which
# nothing prompts you to do.
#
# The trigger is change rather than the calendar. A document nobody has touched
# does not need re-reading; one that has grown by a quarter since it was last
# read has become a different document, which is how docs/3.3 went from 629
# lines to 986 in two days with every addition justified on its own.
#
# Stamp a document by putting this near its title, after reading it whole:
#
#     *Reviewed whole at `<short-sha>` (YYYY-MM-DD).*
REVIEW_THRESHOLD_PERCENT=25
echo "==> Documentation review"
DOC_UNSTAMPED=""
DOC_FLAGGED=0
DOC_OK=0
for doc in docs/*.md docs/changes/*.md; do
  [[ -f "$doc" ]] || continue
  stamp="$(grep -m1 -oE 'Reviewed whole at `[0-9a-f]+`' "$doc" 2>/dev/null | grep -oE '[0-9a-f]+' || true)"
  if [[ -z "$stamp" ]]; then
    DOC_UNSTAMPED="$DOC_UNSTAMPED ${doc#docs/}"
    continue
  fi
  # Lines added plus removed since the stamp, against the document's length now.
  churn="$(git diff --numstat "$stamp..origin/main" -- "$doc" 2>/dev/null \
    | awk '{print $1 + $2}' || true)"
  churn="${churn:-0}"
  total="$(wc -l < "$doc" | tr -d ' ')"
  (( total == 0 )) && total=1
  percent=$(( churn * 100 / total ))
  if (( percent >= REVIEW_THRESHOLD_PERCENT )); then
    printf '    %-42s %s%% changed since %s — worth re-reading\n' "${doc#docs/}" "$percent" "$stamp"
    DOC_FLAGGED=$((DOC_FLAGGED + 1))
  else
    DOC_OK=$((DOC_OK + 1))
  fi
done
if [[ -n "$DOC_UNSTAMPED" ]]; then
  # Naming all two dozen is noise. The longest are where a read pays most, and
  # are the ones that grew without anybody looking at the whole.
  # shellcheck disable=SC2086
  set -- $DOC_UNSTAMPED
  printf '    %-42s %s\n' "never reviewed" "$# documents"
  for doc in $(wc -l docs/*.md 2>/dev/null | sort -rn | head -4 | awk '{print $2}'); do
    [[ "$doc" == "total" ]] && continue
    case " $DOC_UNSTAMPED " in
      *" ${doc#docs/} "*) printf '    %-42s %s lines\n' "  ${doc#docs/}" "$(wc -l < "$doc" | tr -d ' ')" ;;
    esac
  done
fi
(( DOC_FLAGGED == 0 && DOC_OK > 0 )) && printf '    %s\n' "$DOC_OK reviewed and little changed since"
echo

echo "==> Open changes"
printf "    %-4s %-${TITLE_WIDTH}s %-16s %s\n" "#" "TITLE" "TYPE" "STATE"
printf '    '; printf '%*s' $((TITLE_WIDTH + 44)) '' | tr ' ' '-'; echo

ISSUES="$(gh issue list --state open --limit 100 \
  --json number,title,labels,milestone \
  -q '.[] | [.number, .title, (.labels | map(.name) | join(",")), (.milestone.title // "")] | @tsv' \
  2>/dev/null || true)"

if [[ -z "$ISSUES" ]]; then
  echo "    (none open)"
else
  while IFS=$'\t' read -r num title labels milestone; do
    [[ -z "$num" ]] && continue
    TYPE="$(type_of "$labels")"
    state="$(state_of_issue "$num" "$TYPE")"
    [[ -n "$milestone" ]] && state="$state · $milestone"
    printf "    %-4s %s %-16s %s\n" "$num" "$(fit_title "$title")" "$TYPE" "$state"
  done <<< "$(printf '%s' "$ISSUES" | sort -n)"
fi
echo

# Closed issue + open milestone = the work is done but has not shipped.
# This is the section that answers "what is waiting to go out", which is the
# question the issue list alone cannot answer.
echo "==> Done, not yet released"
AWAITING="$(gh issue list --state closed --limit 100 \
  --json number,title,milestone,labels \
  -q '.[] | select(.milestone != null)
      | [.number, .title, .milestone.title, ([.labels[].name] | join(","))] | @tsv' \
  2>/dev/null || true)"

OPEN_MILESTONES="$(gh api "repos/{owner}/{repo}/milestones?state=open" \
  -q '.[].title' 2>/dev/null || true)"

FOUND=0
if [[ -n "$AWAITING" && -n "$OPEN_MILESTONES" ]]; then
  while IFS=$'\t' read -r num title milestone labels; do
    [[ -z "$num" ]] && continue
    # An open milestone alone is not enough. The lane milestones — fasttrack,
    # minor, major, merge — never close, that being what makes them lanes, so
    # this test was permanently true for anything closed against one.
    grep -qxF "$milestone" <<< "$OPEN_MILESTONES" 2>/dev/null || continue
    # And a change that never reaches users has nothing to wait for. It went
    # live when it merged, so listing it as "not yet released" is wrong rather
    # than merely noisy — it invents a queue that does not exist.
    [[ "$(reach_of "$labels")" == "reaches users" ]] || continue
    printf "    %-4s %s %s\n" "$num" "$(fit_title "$title")" "$milestone"
    FOUND=1
  done <<< "$AWAITING"
fi
(( FOUND == 0 )) && echo "    (nothing waiting — everything closed either is live or does not reach users)"

echo
echo "    Types: docs/3.3, \"The six types of change\"."
echo "    State comes from \"Refs #N\" in the commits, so a branch covering"
echo "    several issues shows under each. A change with neither a Refs"
echo "    trailer nor an issue-<N>-* branch reads \"not started\"."
