#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Build the container images locally and ship them to the
# deployment VM.
#
# Why not build on the VM: the Always Free shape this project runs on
# (VM.Standard.E2.1.Micro) has 1GB RAM, which isn't enough to compile the
# Rust/wasm workspace. So this always builds locally (where there's room)
# and transfers the finished images instead of the source — `docker save`,
# scp, `docker load`, `docker compose up`. See docs/3.3-testing-ci-and-release.md's
# "Container Deployment" section for the full story, including the Oracle
# Cloud networking setup this assumes is already in place.
#
# What gets built is a *fresh checkout of a commit*, never the working
# tree. The build happens in a throwaway `git worktree`, so nothing on
# your disk — the branch you have checked out, staged changes, a
# half-finished edit — can reach production. Two things follow from that:
# deploying an older release is an ordinary operation rather than a
# manoeuvre (pass its ref), and "what is running in production" is always
# answerable from source control alone.
#
# Refuses to run unless: the commit is on origin/main, CI passed for it,
# the rehearsal host is currently running it, and production's database hasn't
# already moved past the schema this build knows. See the checks below.
#
# The deploy itself, once those pass:
#
#   1. build the images from a clean checkout, transfer them
#   2. retag the live images :previous, so rollback is a retag not a rebuild
#   3. stop the server and snapshot the database
#   4. apply migrations on their own — a failure here aborts with the
#      previous version still installed, rather than taking the site down
#   5. start the new version
#   6. smoke test the public URL for the expected version, and roll back
#      automatically if it doesn't appear
#
# Steps 3-6 are what make a bad release recoverable in seconds instead of a
# rebuild; `scripts/rollback.sh` does the same thing by hand.
#
# Usage:
#   ./scripts/deploy.sh                # deploy HEAD
#   ./scripts/deploy.sh <commit-ish>   # deploy a specific commit/tag/branch,
#                                      # e.g. `./scripts/deploy.sh prod-0.4.12`
#                                      # to roll back to a previous release
#
# Configure via environment variables (defaults match the current VM):
#   DEPLOY_ENV       production | rehearsal (default: production)
#   DEPLOY_HOST      Public IP or hostname of the VM (default: 129.151.69.246)
#   DEPLOY_USER      SSH user (default: ubuntu)
#   DEPLOY_SSH_KEY   Private key path (default: ~/.ssh/oracle_tile_lite_elite)
#   DEPLOY_REMOTE_DIR  Directory on the VM holding docker-compose.yml (default: tile-lite-elite)
#
# Everything defaults to production, so an unset environment behaves exactly
# as this script always has. `scripts/deploy-rehearsal.sh` sets the lot.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# How many commits mention an issue. Shared with `verify.sh`, which carried the
# identical defect because it carried an identical copy of the line.
#
# `BASH_SOURCE` rather than `$0`: when this file is *sourced* — which
# `deploy-release.test.sh` does, to reach its functions — `$0` is still the
# outer script, and the path would resolve into `scripts/tests/`.
source "$(dirname "${BASH_SOURCE[0]}")/issue-mentions.sh"

# The newest real release tag other than `$1`, or "" when there is none.
#
# `grep -E` rather than a glob, because a redeploy tag carries a timestamp
# suffix (`prod-0.7.0-20260101T000000Z`) which a glob matches and which would
# then compete to be the predecessor.
#
# `|| true` on the whole pipeline: with no tags, `grep` matches nothing and
# exits 1, which under `set -o pipefail` would abort a deploy that has already
# succeeded. That failure shape has aborted a deploy on this project twice.
previous_release_tag() {
  git -C "$REPO_DIR" tag --list 'prod-*' 2>/dev/null \
    | grep -E '^prod-[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -vxF "$1" \
    | sed 's/^prod-//' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 || true
}

# Publish the GitHub Release for a tag just pushed. $1 tag, $2 version.
#
# GitHub writes the notes from the pull requests merged since the previous
# release, so nobody types a changelog — one that has to be remembered is one
# that stops being written. `docs/4.9` is not replaced by this: a delivery that
# ships no code has no tag for a release to hang on. See docs/3.3 §3.3.1.
#
# Never fatal. Production is already serving the new version by the time this
# runs, so a changelog that fails to post prints the command to run by hand and
# lets the deploy exit 0. Making a green deploy look red is the worse failure.
publish_release() {
  local tag="$1" version="$2" prev
  if [[ "$tag" != "prod-$version" ]]; then
    echo "==> No release: $tag is a redeploy of a version already released"
    return 0
  fi
  prev="$(previous_release_tag "$tag")"
  local args=(--generate-notes --verify-tag --title "$version")
  # Without a start tag GitHub walks back to the first commit, so the first
  # release ever published would carry the entire history as its notes.
  [[ -n "$prev" ]] && args+=(--notes-start-tag "prod-$prev")
  if gh release create "$tag" "${args[@]}" > /dev/null 2>&1; then
    echo "==> Published release $version${prev:+ (notes since $prev)}"
  else
    echo "    warning: could not publish the GitHub release for $tag" >&2
    echo "    run: gh release create $tag --generate-notes --title $version" >&2
  fi
}

# Close the milestone this release shipped, and open the next — or explain why
# not. Three ways through, and the middle one is why this is a function: the
# normal-release path used to sit *inside* the emergency branch, so a normal
# release silently did nothing while saying nothing (#150). Nothing noticed for
# a release and a half, because nothing could reach this code without deploying.
#
# Reads the globals the deploy has already established: IS_RELEASE, EMERGENCY,
# DEPLOY_ENV, DEPLOYED_VERSION, DEPLOY_TAG, TARGET_SHA, NEXT_VERSION.
# What a deploy does to one issue in the milestone it is shipping.
#
# **It advances the phase; it does not close.** A project used to be closed here,
# which took with it the one moment its post-deployment review was meant to
# happen — seven projects closed, no review ever written, and the `Post-deployment`
# column unreachable because the board filters `is:open` (#263). Leaving it open
# at that phase makes the column mean *awaiting its review*.
#
# What follows it is `Project Closedown` — *lessons learnt completed* — so the
# two halves are separable: a project at `Post-deployment` still owes its review,
# one at `Project Closedown` owes only its closing. Nothing here sets that second
# phase: writing the review is the act that earns it, and no script can tell that
# it happened.
#
# The `Released in` comment still goes on, because that record was never the
# problem. `--reason completed` is still explicit where a close does happen, for
# the reason it always was: `stateReason` is how a closure's reason is recorded,
# and this is the one site that closes with no human present.
#
# `setIssueFieldValue` rather than `createIssueFieldValue`: the latter refuses
# when a value already exists, and by this point every project has a phase.
#
# Note `issueFields:[…]`, a **list** — it differs from `createIssueFieldValue`'s
# singular `issueField:{…}`, and the first version of this said the latter. The
# stub matched on the string `setIssueFieldValue` and answered success, so a
# malformed mutation passed its test; it was caught by running the same call by
# hand against the real API. The test below now asserts the shape, because a
# stub that accepts anything is a test of nothing.
#
# **A non-project is still closed.** Milestones belong to projects (docs/3.6), so
# anything else here is an anomaly the gate above has already called out — and
# closing it is what used to happen, so nothing new is invented for a case that
# should not arise.
PHASE_FIELD_ID="${PHASE_FIELD_ID:-IFSS_kgDOAsBg2A}"
PHASE_POST_DEPLOYMENT_ID="${PHASE_POST_DEPLOYMENT_ID:-IFSSO_kgDOBNDpVw}"

# Issues that this release's commits mention while still filed under a
# placeholder milestone. One line each on stdout, empty when there are none.
#
# `patch`, `minor` and `major` are placeholders — a change sits in one until the
# version it ships in is known, and is moved before the deploy (owner,
# 2026-08-30). Nothing checked that the move happened.
#
# **`no-release` is the fourth, and the one it actually happens in.** It held 5
# open and 60 closed issues on 2026-09-01, against none in the other three, and
# both projects shipping in 0.7.1 were filed under it — the gate said nothing,
# and the milestone was corrected by hand on the morning of the deploy. It reads
# as safe because it is true when a change is triaged: this needs no release of
# its own. It stops being true the moment the change is also inside an image,
# and nothing re-asks. #281.
#
# **It fails more quietly than it looks.** `settle_milestone` reads the milestone
# named after the version being deployed, so a milestone called `patch` is never
# the one a deploy consults. The risk was never that its contents ship by
# accident; it is that they ship and are then never closed, announced, or
# deferred — they simply stop being tracked.
#
# A function rather than inline, so it can be tested: the gate around it is only
# reachable by running a deploy, which is how #150 survived in the code beside
# it. Reuses `commits_mentioning` rather than inverting it, so both halves of the
# gate share one definition of "this release mentions it".
placeholder_shipping() {
  local ref="$1" milestone num title
  for milestone in patch minor major no-release; do
    while IFS=$'\t' read -r num title; do
      [[ -z "$num" ]] && continue
      if (( $(commits_mentioning "$ref" "$num") > 0 )); then
        printf '    #%-5s %-12s %s   <-- SHIPPING, FILED UNDER %s\n' \
          "$num" "placeholder" "${title:0:44}" "$milestone"
      fi
    done < <(gh issue list --milestone "$milestone" --state open \
               --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null || true)
  done
}

# --- The build artefact -------------------------------------------------------
#
# **One build per commit, shared by every environment it is deployed to.**
# Rehearsal used to prove *a* build of commit X and production shipped *a
# different* build of it: `deploy-rehearsal.sh` is this script with another
# host, and each run built its own images. Docker builds are not
# bit-reproducible — base tags move, apt mirrors move, the toolchain resolves at
# build time — so "the same commit" was never the same bytes. #214 R1.
#
# The artefact is `artifacts/<full sha>.tar.gz`, git-ignored, and a build runs
# only when that file is absent. Keyed by the full SHA rather than the short
# one, so it is the commit that identifies it and not an abbreviation that can
# collide, and so preview can key on the same thing when R2 arrives: any branch
# or commit builds, and the artefact exists per commit however the ref was
# named.
#
# **Sameness is proved by digest, not by version.** A rebuild of one commit
# stamps the same version, so `/health` cannot tell two builds apart, which is
# exactly what made the old check blind to the thing this fixes.
# shellcheck source=scripts/shipping-paths.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipping-paths.sh"

ARTIFACT_DIR="${ARTIFACT_DIR:-$REPO_DIR/artifacts}"
ARTIFACT_KEEP="${ARTIFACT_KEEP:-5}"

artifact_path() { printf '%s/%s.tar.gz' "$ARTIFACT_DIR" "$1"; }

# The digest of a built artefact, recorded beside it at build time so a later
# deploy can prove it is loading what was built rather than trusting the name.
artifact_digest() { sha256sum "$1" | cut -d' ' -f1; }

# Refuses rather than deploying something that is not what was built. A cache
# that has been truncated by a full disk, or half-written by an interrupted
# build, is the case this catches: the name still matches the commit.
verify_artifact() {
  local tar="$1" recorded actual
  [[ -f "$tar.sha256" ]] || { echo "error: $tar has no recorded digest." >&2; return 1; }
  recorded="$(cat "$tar.sha256")"
  actual="$(artifact_digest "$tar")"
  if [[ "$recorded" != "$actual" ]]; then
    echo "error: $(basename "$tar") does not match its recorded digest." >&2
    echo "       recorded $recorded" >&2
    echo "       actual   $actual" >&2
    echo "       Delete it and deploy again to rebuild." >&2
    return 1
  fi
  printf '%s' "$actual"
}

# Builds the images from the worktree and saves them, or reuses the artefact
# that is already there. Writes through a temporary name so an interrupted
# build cannot leave a short file that looks complete.
build_artifact() {
  local sha="$1" worktree="$2" tar tmp
  tar="$(artifact_path "$sha")"
  mkdir -p "$ARTIFACT_DIR"

  if [[ -f "$tar" ]]; then
    echo "==> Reusing the artefact already built for $sha"
    return 0
  fi

  echo "==> Building images from a clean checkout of $sha (the slow step, ~2-3 min)"
  if ! docker compose -f "$worktree/docker-compose.yml" build; then
    echo "error: the image build failed. Nothing has been cached." >&2
    return 1
  fi

  # Checked rather than left to `set -e`, because errexit does not apply inside
  # a function whose caller has disabled it — and the failure that gets through
  # renames a truncated `.partial` into place, which is an artefact that looks
  # built and is not. Found by the test for exactly this, 2026-09-01.
  echo "==> Exporting images"
  tmp="$tar.partial"
  if ! docker save tile-lite-elite-server:latest tile-lite-elite-web:latest | gzip > "$tmp"; then
    rm -f "$tmp"
    echo "error: saving the images failed. Nothing has been cached." >&2
    return 1
  fi
  mv "$tmp" "$tar"
  artifact_digest "$tar" > "$tar.sha256"
}

manifest_path() { printf '%s/%s.manifest' "$ARTIFACT_DIR" "$1"; }

# What is in this build, written beside the artefact it describes — #288 R1.
#
# **"Is this change in the build?" is answered from the artefact, not from a
# plan describing it.** The milestone says what a release is *meant* to carry;
# this says what it *does*. Both have been wrong, in opposite directions, within
# a week: the milestone gate read prose as shipping (#320), and #310's
# announcement was lost with no record that it had not run.
#
# **Pure git, deliberately.** No `gh`, no network. A manifest that cannot be
# written when GitHub is unreachable would be missing exactly when a deploy is
# most interesting, and every line here is derivable from the repository.
#
# R2 is the digest line: the manifest names the bytes it describes, so the two
# cannot be separated by being copied apart.
write_manifest() {
  local sha="$1" digest="$2" out prev range n
  out="$(manifest_path "$sha")"

  # The previous production tag: the newest one that is an **ancestor of this
  # commit**, not simply the newest that exists. Taking the latest tag gives an
  # empty range whenever the commit being built already carries one — which is
  # every rebuild of a released commit, and every rollback. Found by asking for
  # a manifest of 9293893, which is what prod-0.7.2 points at: it reported
  # "commits (0)" and looked like a working answer.
  #
  # `$sha^` so the commit's own tag is skipped. Absent for the first ever build,
  # and for a repository whose tags have not been fetched — reported rather than
  # guessed.
  prev="$(git -C "$REPO_DIR" describe --tags --match 'prod-[0-9]*' --abbrev=0 "$sha^" </dev/null 2>/dev/null || true)"
  if [[ -n "$prev" ]]; then range="$prev..$sha"; else range="$sha"; fi

  {
    printf 'artefact  %s.tar.gz
' "$sha"
    printf 'digest    sha256:%s
' "$digest"
    printf 'commit    %s
' "$sha"
    if [[ -n "$prev" ]]; then
      printf 'since     %s (%s)
' "$prev" "$(git -C "$REPO_DIR" rev-parse --short "$prev")"
    else
      printf 'since     (no prod-* tag — every commit reachable is listed)
'
    fi
    printf 'built     %s

' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    n="$(git -C "$REPO_DIR" rev-list --count "$range" 2>/dev/null || echo 0)"
    printf 'commits (%s), * reaches the image
' "$n"
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      if touches_image "$c"; then printf '  * '; else printf '    '; fi
      printf '%s  %s
' "$(git -C "$REPO_DIR" rev-parse --short "$c")"                         "$(git -C "$REPO_DIR" log -1 --format=%s "$c")"
    done < <(git -C "$REPO_DIR" rev-list "$range" 2>/dev/null || true)

    printf '
issues claimed in this range
'
    # Claimed, not mentioned: the `Refs`/`Closes` trailer, which is what
    # `commits_mentioning` reads (#320). A commit citing an issue in prose is
    # not shipping it, and reading it as such refused the 0.7.2 release.
    while IFS= read -r num; do
      [[ -n "$num" ]] || continue
      printf '  #%-6s %s commit(s)%s
' "$num"         "$(git -C "$REPO_DIR" rev-list --count "$range" -E --grep="(Refs|Closes) #${num}\b" 2>/dev/null || echo 0)"         "$(issue_touches_image "$num" "$range" && printf ', reaches the image' || true)"
    done < <(git -C "$REPO_DIR" log --format=%B "$range" 2>/dev/null                | grep -oE '(Refs|Closes) #[0-9]+' | grep -oE '[0-9]+' | sort -un || true)
  } > "$out"
  printf '%s' "$out"
}

# Does any commit claiming this issue, in this range, reach the image?
issue_touches_image() {
  local num="$1" range="$2" c
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    touches_image "$c" && return 0
  done < <(git -C "$REPO_DIR" rev-list "$range" -E --grep="(Refs|Closes) #${num}\b" 2>/dev/null || true)
  return 1
}

# Does the plan agree with the build? — #288 R3.
#
# **One direction only, and the design asked for two.** It proposed reporting
# both *an image-touching issue with no milestone* and *a milestone issue with
# no commit in the range*. The second is already the milestone gate's
# `UNBUILT` check, which prints "Nothing in this release mentions:" and asks
# before deploying — so writing it again here would be a second statement of one
# rule, which is what `docs/3.6` calls a defect whichever copy is right.
#
# The first is new: **nothing today notices a change that reaches players and is
# in no milestone.** The gate looks outward from the plan and finds issues that
# were planned and not built; this looks outward from the build and finds the
# opposite. That asymmetry is the reason the gate could pass while 0.7.2 shipped
# a commit nobody had filed.
#
# **A check, never a gate**, and it runs after the deploy has succeeded: a
# missing milestone is a record to correct, not a reason to withhold a release
# that is already live.
report_plan_disagreement() {
  local sha="$1" version="$2" range prev unfiled="" num meta
  prev="$(git -C "$REPO_DIR" describe --tags --match 'prod-[0-9]*' --abbrev=0 "$sha^" </dev/null 2>/dev/null || true)"
  [[ -n "$prev" ]] && range="$prev..$sha" || range="$sha"

  # **Has it a milestone at all**, not *is it in this one*. The first version
  # asked the narrower question and reported #304 and #306 as unfiled — they
  # carry `0.7.1a` and `0.7.1b`, which is exactly right for a delivery that
  # shipped no image. An issue may legitimately ride a release under an earlier
  # milestone; what it may not do is reach players under none.
  while IFS= read -r num; do
    [[ -n "$num" ]] || continue
    issue_touches_image "$num" "$range" || continue
    # One call for both facts. A **Requirement** is skipped: `docs/3.6` 1.1 —
    # *"Milestones go with project deliveries, and not with requirements"* — so
    # asking one to carry a milestone asks for something the process forbids.
    # #277 was reported until this was added, because a commit claiming it
    # touched `Cargo.lock` while adding a dev-dependency.
    meta="$(gh issue view "$num" --json milestone,issueType \
              --jq '[(.issueType.name // ""), (.milestone.title // "")] | @tsv' \
              </dev/null 2>/dev/null || true)"
    [[ "$(cut -f1 <<< "$meta")" == "Requirement" ]] && continue
    [[ -n "$(cut -f2 <<< "$meta")" ]] && continue
    # A parent, for the same reason as the Requirement above: the process says
    # it needs no milestone, so asking for one asks for something forbidden.
    # Checked last because it costs a second API call, and only issues that got
    # this far — not a Requirement, and carrying no milestone — can reach it.
    is_parent "$num" && continue
    unfiled="$unfiled $num"
  done < <(git -C "$REPO_DIR" log --format=%B "$range" </dev/null 2>/dev/null \
             | grep -oE '(Refs|Closes) #[0-9]+' | grep -oE '[0-9]+' | sort -un || true)

  if [[ -n "$unfiled" ]]; then
    echo "==> These reach the image and are in no milestone:$unfiled" >&2
    echo "    They shipped in $version. Give them a milestone so the record says so." >&2
    echo "    An earlier milestone is fine — a letter for a delivery that shipped no image." >&2
  fi
}

# Keeps the last few and removes the rest. It is a cache: losing one costs a
# rebuild of a known commit, not a release, which is why this can be blunt.
prune_artifacts() {
  local keep="${1:-$ARTIFACT_KEEP}" old
  [[ -d "$ARTIFACT_DIR" ]] || return 0
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    rm -f "$old" "$old.sha256" "${old%.tar.gz}.manifest"
  done < <(ls -1t "$ARTIFACT_DIR"/*.tar.gz 2>/dev/null | tail -n "+$((keep + 1))")
}

# Does this issue have work packages of its own? A parent has no delivery role,
# so it carries no milestone and none is expected of it — `CLAUDE.md`, and D51.
#
# **One definition, used by both places in this file that ask.** `settle_issue`
# was given the parent exemption on 2026-09-09 and
# `report_plan_disagreement` was not, so the 0.8.0 rehearsal and deploy both
# asked #301, #344 and #297 for a milestone the process says they must not need
# — #370. Two copies of a rule is how one of them comes to be wrong.
#
# The REST sub-issues endpoint, not GraphQL: `{owner}` and `{repo}` expand in a
# REST path and not in a GraphQL document, and deploy.sh resolves neither.
#
# `verify.sh` holds a third copy. Left there deliberately for now: merging the
# three means a shared file and a new artefact to register, which is a larger
# change than the defect warrants — recorded against #370 R3 instead.
# The number of the issue this one is a work package of, or empty. See the twin
# in verify.sh: a package split out after its commits landed carries its
# parent's number in the trailer and cannot be made to carry its own. #375.
parent_of() {
  # `gh issue view --json parent`, not the REST issue object: REST carries
  # `parent_issue_url` and no `parent.number`, so the obvious REST read returns
  # empty for every issue and the check silently reverts to its old behaviour.
  gh issue view "$1" --json parent --jq '.parent.number // ""' 2>/dev/null || true
}

is_parent() {
  local n
  n="$(gh api "repos/{owner}/{repo}/issues/$1/sub_issues" \
    --jq '[.[] | select(.type.name == "Project")] | length' 2>/dev/null || echo 0)"
  [[ "${n:-0}" != "0" ]]
}

settle_issue() {
  local issue="$1" kind phase node

  # **A parent's milestone is ignored** — D51, and the owner on 2026-09-08:
  # *"as with Route a parent does not need a milestone, but one can be set. It
  # should be ignored."* #71 carries `1.0.0` as a target while its work packages
  # carry the deliveries, so a 1.0.0 release would otherwise comment "released"
  # on a parent that shipped nothing and advance it to Post-deployment — a
  # phase D51 says oversight never reaches.
  #
  # Read before anything is written, because the comment is not undoable.
  if is_parent "$issue"; then
    echo "    skipped #$issue — a parent, whose milestone is a target and not a delivery"
    return
  fi

  gh issue comment "$issue" \
    --body "Released in $DEPLOY_TAG — production is running $DEPLOYED_VERSION+$TARGET_SHA." \
    > /dev/null 2>&1 \
    || echo "    warning: could not comment on #$issue" >&2

  kind="$(gh issue view "$issue" --json issueType --jq '.issueType.name // ""' 2>/dev/null || true)"
  if [[ "$kind" != "Project" ]]; then
    if gh issue close "$issue" --reason completed > /dev/null 2>&1; then
      echo "    closed #$issue — not a project, so no review to wait for"
    else
      echo "    warning: could not close #$issue" >&2
    fi
    return
  fi

  # Said out loud when it is not what was expected. A project reaching a release
  # from `Development` skipped user testing, and advancing it silently would hide
  # that — the same reasoning as the gate above calling out an issue that no
  # commit mentions, because that too is decidable.
  phase="$(gh issue view "$issue" --json issueFieldValues \
    --jq '[.issueFieldValues[]? | select(.field.name == "Phase") | .name] | first // ""' \
    2>/dev/null || true)"
  if [[ -n "$phase" && "$phase" != "Deployment" ]]; then
    echo "    note: #$issue was at '$phase', not 'Deployment', when it shipped" >&2
  fi

  node="$(gh issue view "$issue" --json id --jq .id 2>/dev/null || true)"
  if [[ -n "$node" ]] && gh api graphql \
      -f query='mutation($i:ID!,$f:ID!,$o:ID!){setIssueFieldValue(input:{issueId:$i,issueFields:[{fieldId:$f,singleSelectOptionId:$o}]}){clientMutationId}}' \
      -f i="$node" -f f="$PHASE_FIELD_ID" -f o="$PHASE_POST_DEPLOYMENT_ID" > /dev/null 2>&1; then
    echo "    #$issue -> Post-deployment, left open for its review"
  else
    # Deliberately not falling back to closing. Closing is the behaviour this
    # change exists to remove, and doing it because a field could not be set
    # would restore the defect at exactly the moment nobody is watching.
    echo "    warning: could not set the phase on #$issue — it stays open at '${phase:-unset}'" >&2
  fi
}

settle_milestone() {
  if (( ! IS_RELEASE )); then
    echo "==> No milestone change: a $DEPLOY_ENV deploy has not reached users"
  elif [[ -n "$EMERGENCY" ]]; then
    # The tag and the version bump still happen above: those are facts about what
    # is running, and letting production and the repo disagree would be worse
    # than the emergency. Closing a milestone is a different kind of statement —
    # that a scope completed the normal process — which is precisely what did not
    # happen. The retrospective issue below carries the record instead, and
    # whoever reviews it closes what actually shipped.
    echo "==> No milestone change: an emergency deploy has not been through the normal process"
  else
    # Everything from here is the *normal release* path. It used to sit inside
    # the emergency branch above — so a normal release silently did nothing and
    # said nothing, while an emergency would have closed the milestone directly
    # after printing that it would not. Introduced by 89f249a when the emergency
    # path was added, and first bit on 0.6.0, whose eleven issues and milestone
    # were closed by hand afterwards.
    # `--paginate` on both milestone reads. One page is 30 and this repository
    # passed that before 0.8.0 — see #377, where the unpaginated `state=all`
    # read below could not see `0.8.1` on page 2, tried to create it, and was
    # refused 422. Only 8 milestones are open today so this call was correct,
    # but it is the same latent bug and a release should not depend on the
    # count staying under a page.
    MILESTONE="$(gh api --paginate "repos/{owner}/{repo}/milestones?state=open" \
      --jq ".[] | select(.title == \"$DEPLOYED_VERSION\") | .number" 2>/dev/null || true)"
    if [[ -n "$MILESTONE" ]]; then
      echo "==> Settling milestone $DEPLOYED_VERSION — projects advance to Post-deployment"
      for ISSUE in $(gh issue list --milestone "$DEPLOYED_VERSION" --state open \
        --json number --jq '.[].number' 2>/dev/null || true); do
        settle_issue "$ISSUE"
      done
      gh api --method PATCH "repos/{owner}/{repo}/milestones/$MILESTONE" \
        -f state=closed > /dev/null 2>&1 \
        && echo "    milestone $DEPLOYED_VERSION closed" \
        || echo "    warning: could not close milestone $DEPLOYED_VERSION" >&2
    fi

    # The tree has just moved to NEXT_VERSION, so anything reported from here
    # belongs to that release. Creating it now means an issue never has to
    # wait for a milestone to exist before it can be filed.
    if [[ "${DEPLOY_SKIP_BUMP:-}" != "1" ]] \
      && ! gh api --paginate "repos/{owner}/{repo}/milestones?state=all" \
        --jq '.[].title' 2>/dev/null | grep -qx "$NEXT_VERSION"; then
      # Reported either way. Previously the `&& echo` was the last statement in
      # this function, so a creation that failed made the whole settle step
      # report exit 1 — which is how 0.8.0 ended by printing three remedies
      # that were already done. A failure here is worth saying out loud; it is
      # not worth claiming the milestone was not settled.
      if gh api repos/{owner}/{repo}/milestones -f title="$NEXT_VERSION" \
        -f description="Changes on main not yet in production." > /dev/null 2>&1; then
        echo "    opened milestone $NEXT_VERSION for what comes next"
      else
        echo "    warning: could not open milestone $NEXT_VERSION" >&2
      fi
    fi
  fi

  # The settle step succeeded if it got here: every failure above is reported as
  # a warning and none of them means the release was not settled. Without this
  # the status is whatever the last `if` happened to leave behind. #377 R2.
  return 0
}
# The post-deployment checks that were waiting for exactly this.
#
# A project can reach `Post-deployment` owing a check that cannot be answered
# until a *later* release: #214 compares this release's image digest against the
# previous one, and before a second release there is nothing to compare. The
# `Release Check` label marks those, `actions.py` shows them as waiting rather
# than due, and this is the moment they stop waiting (#310).
#
# A check and never a gate. It runs after everything else has succeeded, prints,
# and returns 0 whatever happens — a reminder that could fail a deploy would be
# worse than no reminder. Failure to reach GitHub is silent for the same reason:
# the release has already happened and this cannot unhappen it.
#
# A function so the tests can reach it. Everything it needs is a parameter,
# because the globals it would otherwise read are set half a script away.
announce_release_checks() {  # $1 = IS_RELEASE, $2 = DEPLOY_ENV
  local is_release="$1" env="$2" listing
  (( is_release )) || return 0
  [[ "$env" == "production" ]] || return 0
  listing="$(gh issue list --label "Release Check" --state open \
      --json number,title --jq '.[] | "  #\(.number)  \(.title)"' 2> /dev/null || true)"
  [[ -n "$listing" ]] || return 0
  echo ""
  echo "==> These were waiting for a release to check against — now they can be:"
  printf '%s\n' "$listing"
  echo "    Answer each in its issue, then take the label off."
  return 0
}


# --- Past this line, production is live: report and continue -----------------
#
# D41 (#321). Owner, 2026-09-05: *"an error stops the scripts when we want the
# script to continue. It should report the error but continue processing the
# script"*, and *"failures before the deploy is complete should stop the script,
# but once the deploy is successful it should continue."*
#
# 0.7.2 is why. The version bump's commit was refused by the pre-commit image
# rule (#316) and, being unguarded under `set -e`, ended the script — so the
# milestone was never settled and `announce_release_checks` never ran. Every
# success line had already printed, so the deploy read as complete. The
# milestone was fixed by hand 45 minutes later; the announcement could not be,
# because it reports a moment rather than a state, and #310's R2 is still
# outstanding as a result.
#
# **Each command is checked explicitly rather than a block being wrapped.**
# Bash suppresses `errexit` for the whole body of a function invoked in a
# condition, so a wrapped block runs on past its own failure and returns the
# status of whatever came last. Measured before relying on it: a two-line test
# ran the statement after `false` in both a plain `if` and a subshell that
# re-enabled `set -e`.
#
# **Each step carries its own remedy**, because *"needs doing by hand"* is not a
# thing anybody can act on at the end of a deploy. Reviewing what a failure
# reports is part of the design (docs/3.6): the moment it is read is the moment
# nobody can go back and add detail to it. The exit code is reported for the
# same reason — `git commit` returning 1 and returning 128 are different
# problems, and only one of them is the pre-commit hook.
POST_DEPLOY_FAILED=()
post_deploy() {
  local what="$1" remedy="$2"; shift 2
  local rc=0
  "$@" || rc=$?
  if (( rc != 0 )); then
    POST_DEPLOY_FAILED+=("$what (exit $rc) — $remedy")
    echo "    warning: $what failed with exit $rc — production is live on $DEPLOYED_VERSION, continuing" >&2
    echo "             to finish by hand: $remedy" >&2
    return 1
  fi
}

# Sourced by scripts/tests/deploy-release.test.sh, which exercises the two
# functions above directly. Everything below this line is the deploy itself and
# must not run when sourced.
if [[ "${DEPLOY_SH_FUNCTIONS_ONLY:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi
DEPLOY_ENV="${DEPLOY_ENV:-production}"
DEPLOY_HOST="${DEPLOY_HOST:-129.151.69.246}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"
# Production is gated on both hosts, because they answer different questions.
#
# The rehearsal host answers "did the release mechanism work against a real
# host", which is a far stronger guarantee than "did you look at it on
# localhost" — and when it arrived it replaced the preview check on exactly
# that reasoning. That was half right. Stronger at proving the *deploy*, and
# no answer at all to the other question preview is for: did somebody use the
# change and find it does what was wanted. The two were one environment before
# they were split, which is how one check came to stand for both.
#
# STAGING_URL is still honoured so an existing environment or muscle-memory
# override keeps working.
REHEARSAL_URL="${REHEARSAL_URL:-${STAGING_URL:-https://129.151.84.183.sslip.io}}"
PREVIEW_URL="${PREVIEW_URL:-http://localhost:8081}"
# The URL of the host this script is acting on — production by default, the
# rehearsal host when a wrapper says so. Named TARGET_URL rather than
# PROD_URL because it is not always production: deploy-preview.sh and
# status.sh both use PROD_URL to mean the *live site*, and one name meaning
# both "my target" and "the live site" in scripts that run in the same
# session is how a value set for one silently changes the other (#24).
# Whether TARGET_URL came from the environment, recorded before defaulting —
# the guard below needs to tell "the caller set it" from "we defaulted it".
TARGET_URL_FROM_ENV="${TARGET_URL:+yes}"
TARGET_URL="${TARGET_URL:-https://tileliteelite.com}"
if [[ -n "${PROD_URL:-}" && -z "$TARGET_URL_FROM_ENV" ]]; then
  echo "error: PROD_URL is set but this script now reads TARGET_URL." >&2
  echo "       It was renamed because PROD_URL means the live site elsewhere;" >&2
  echo "       silently honouring it here would smoke-test the wrong host." >&2
  echo "       Set TARGET_URL=${PROD_URL} instead." >&2
  exit 1
fi
# How many pre-deploy database snapshots to keep on the VM. Rollback is
# expected to happen immediately if at all (a later rollback would discard
# real play), so depth beyond the last few releases has no consumer.
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-5}"

case "$DEPLOY_ENV" in
  production|rehearsal) ;;
  *) echo "error: DEPLOY_ENV must be 'production' or 'rehearsal', not '$DEPLOY_ENV'." >&2; exit 1 ;;
esac

# --- Emergency changes -------------------------------------------------------
#
# `DEPLOY_EMERGENCY="<why>"` — restore service when the normal path is too slow.
# See docs/3.3, "Emergency changes", which says the important part: **try
# rollback first.** `rollback.sh` is a retag and a restore, needs no build and
# no transfer, and has no gates because it only ever moves to something that
# was already running. This path is for when rolling back cannot help — a bug
# that has been live for a week, or an outage caused by something outside the
# image.
#
# It skips exactly two gates: standing this commit up on preview, and on
# rehearsal.
#
# **They cost less than they did.** Until #214 each was a full image build plus a
# transfer; now the artefact is built once for the commit and both reuse it, so
# what is skipped is two transfers and two smoke tests. The build happens either
# way, because an emergency is a new commit. Owner, 2026-09-03: with build-once
# there may not be much time left to save — and what remains is mostly the CI
# wait and the human steps, not the machine ones.
#
# It does **not** skip CI. One complete run, e2e included, is the check worth
# waiting for — it is the only thing between here and production that has
# actually exercised the change. `DEPLOY_SKIP_CI` still exists and still means
# what it did: GitHub itself is unreachable. That is a different problem from
# production being down, and conflating them would let an emergency quietly
# ship something nothing had run.
#
# Nor does it skip the two that are not policy: the commit must be on a remote
# branch, or production runs something that exists only on this machine and
# there is nothing to roll back to or reason about afterwards; and the database
# must not have outrun the image, which is physics rather than process — that
# server would not boot, turning a bug into an outage.
EMERGENCY=""
if [[ -n "${DEPLOY_EMERGENCY:-}" ]]; then
  case "$DEPLOY_EMERGENCY" in
    1|true|yes) EMERGENCY="(no reason given at the time)" ;;
    *)          EMERGENCY="$DEPLOY_EMERGENCY" ;;
  esac
  echo
  echo "  ############################################################"
  echo "  ##  EMERGENCY DEPLOY                                      ##"
  echo "  ##  preview and rehearsal are being skipped.              ##"
  echo "  ##  CI still has to pass, e2e included.                   ##"
  echo "  ############################################################"
  echo "  reason: $EMERGENCY"
  echo
  echo "  Have you tried ./scripts/rollback.sh? It is seconds, not minutes,"
  echo "  and needs no build. Ctrl-C now if you have not."
  echo
fi

# What a *release* means only applies to production: the prod-* tag is the
# deployment log, the version bump moves the tree past what is now live, and
# the milestone closure records what reached users. A rehearsal does none of
# those things — it proves the mechanism. Tagging prod-0.4.19 for a deploy
# that never touched production would corrupt the one record that answers
# "what has actually shipped".
IS_RELEASE=0
[[ "$DEPLOY_ENV" == "production" ]] && IS_RELEASE=1

# `-n` redirects ssh's stdin from /dev/null. Without it ssh reads the
# script's own stdin, and a command run before an interactive prompt
# swallows the answer: rollback.sh's confirmation read hit EOF and
# `set -e` aborted it. Found during the 2026-08-01 rollback drill, on the
# most destructive command in the repo — the one place a prompt must work.
SSH_OPTS=(-n -i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
# The same connection options minus `-n`, which is an ssh-only flag: scp
# rejects it outright ("unknown option -- n") and the transfer dies after the
# images have already been built and compressed. Found by a real deploy —
# every check I had run stopped at the gates and never reached the scp.
SCP_OPTS=(-i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"


cd "$REPO_DIR"

# Which script is this? deploy.sh runs from the working tree, not from the
# commit being deployed — the payload is always a clean worktree checkout,
# but the *script* is whatever is on disk now. So a production deploy made
# while sitting on a feature branch runs that branch's tooling, silently.
# Printing the script's own identity makes that visible in the output
# instead of remembered. See issue #14 for why this is a mitigation rather
# than a fix (the fix is a separate released-scripts checkout, judged not
# worth its own upkeep).
SCRIPT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SCRIPT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCRIPT_DIRTY=""
git diff --quiet -- scripts/ 2>/dev/null || SCRIPT_DIRTY=" (uncommitted changes in scripts/)"
echo "==> $DEPLOY_ENV deploy, using tooling from $SCRIPT_BRANCH@$SCRIPT_SHA$SCRIPT_DIRTY"

# Production should only ever run merged tooling; unmerged tooling belongs on
# the rehearsal host, which is what it is for. Rehearsal deliberately has no
# such guard — a guard there would defeat the environment's purpose.
if (( IS_RELEASE )) && { [[ "$SCRIPT_BRANCH" != "main" ]] || [[ -n "$SCRIPT_DIRTY" ]]; }; then
  echo
  echo "    WARNING: deploying to production with tooling that is not merged."
  echo "    Test tooling changes on the rehearsal host first:"
  echo "        ./scripts/deploy-rehearsal.sh"
  echo
  # Gates-only changes nothing, so there is nothing here to protect production
  # from. Skipping the whole confirmation — the prompt as well as the refusal —
  # is also what lets the gate suite run at all: a test has no terminal.
  #
  # The prompt has to go with it, not just the refusal. Leaving `read` reachable
  # made a gates-only run hang instead of answering, which is the same trap the
  # paragraph below describes and was caught the same way: by running it.
  if [[ "${DEPLOY_GATES_ONLY:-}" == "1" ]]; then
    echo "    (gates only — nothing will be deployed, so not asking)"
  else
    # Refuse rather than block when there is no terminal. A bare `read` with
    # no stdin waits forever, so this hung a non-interactive run instead of
    # failing it — found by testing the guard itself. A deploy that hangs is
    # worse than one that stops, the same lesson as the `timeout 300` around
    # --migrate-only.
    if [[ ! -t 0 ]]; then
      echo "    Not a terminal, so this cannot be confirmed. Refusing." >&2
      echo "    Merge the tooling to main first, or run this interactively." >&2
      exit 1
    fi
    read -r -p "    Type 'production' to run this anyway: " CONFIRM_TOOLING
    if [[ "$CONFIRM_TOOLING" != "production" ]]; then
      echo "    Stopped — nothing was deployed."
      exit 1
    fi
  fi
fi

# Fail fast with a clear message rather than a confusing worktree error
# further down if the ref doesn't exist locally.
DEPLOY_REF="${1:-HEAD}"
if ! TARGET_FULL_SHA="$(git rev-parse --verify "${DEPLOY_REF}^{commit}" 2>/dev/null)"; then
  echo "error: '$DEPLOY_REF' is not a valid local git ref (fetch it first if it's remote-only)" >&2
  exit 1
fi
# `gh run list --commit` matches on the full hash only — a short one silently
# returns no runs, which would make the CI gate below fail every deploy.
TARGET_SHA="$(git rev-parse --short "$TARGET_FULL_SHA")"

# Every gate records that it ran, and the run is refused if the checklist is
# short. "Nothing complained" is not evidence a check happened: a gate that
# silently does not execute — an early return, a refactor that moves it, a
# missing `gh` — reads exactly like one that ran and passed. Two gates here have
# already failed open that way.
#
# So the gates are counted rather than trusted. Adding a gate means adding its
# name to GATES_EXPECTED below, and forgetting to is itself caught, because the
# checklist is what the deploy is verified against.
GATES_RUN=""
note_gate() { GATES_RUN="$GATES_RUN $1"; }

# The working tree has no say in what ships, so a dirty one isn't an error
# here — it simply isn't part of the deploy. Say so rather than staying
# quiet: the previous behaviour (refusing to run until the tree was clean)
# taught the opposite expectation, that deploy.sh builds what you can see.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Note: your working tree has uncommitted changes. They are NOT part of"
  echo "    this deploy — $TARGET_SHA is built from a clean checkout of that commit."
fi

# Refuses to ship a commit that only exists on this machine — if this
# machine were lost before anyone/anything else had a copy, "what's
# actually running in production" would stop being reproducible from
# source control at all. Fetches first so a stale local view of the
# remote can't produce a false pass.
#
# Asks that question directly rather than through the current branch's
# upstream. The property that matters is "this commit is on the remote";
# a branch's tracking config is only ever a proxy for it, and the proxy
# rejected the case this script now exists to support — a commit reached
# by tag or SHA has no `@{u}` at all, so a rollback failed a gate it
# actually passed.
#
# Any remote branch, not `origin/main` specifically. The comment above is
# the rule — "this commit is on the remote" — and pinning it to main was
# stricter than that without saying so. It also blocked a legitimate case:
# deploying a branch deliberately, to trial a change or to rehearse a
# rollback with something you intend to abandon (docs/3.3's "Rollback
# drill"). A branch that has been pushed is just as reproducible as main;
# what must never ship is a commit that exists only on this machine.
#
# `grep -v '\->'` drops the `origin/HEAD -> origin/main` symbolic line,
# which is not a branch and would otherwise make any commit look reachable.
git fetch --quiet origin
REMOTE_BRANCHES="$(git branch -r --contains "$TARGET_FULL_SHA" 2>/dev/null | grep -v '\->' | tr -d ' ' | tr '\n' ' ' || true)"
if [[ -z "$REMOTE_BRANCHES" ]]; then
  echo "error: $TARGET_SHA ($DEPLOY_REF) is not on any remote branch — push it first." >&2
  echo "       Production must only ever run a commit that survives losing this machine." >&2
  exit 1
fi
note_gate on-remote
echo "==> $TARGET_SHA confirmed on the remote ($REMOTE_BRANCHES)"

# Refuses to ship a commit CI hasn't passed. Until this existed, CI was
# only a signal running alongside the release rather than a gate on it: a
# red run stopped nothing, and the only real check was whoever remembered
# to run the suites by hand.
#
# Delegated to ci-status.sh so that the check made by hand at step 1.e and
# the one enforced here are the same code, and cannot answer differently.
#
# **Named run, not any run.** A production deploy ships what is on `main`, so
# the run that answers for it is the push to `main` — and `e2e` is required
# explicitly, because a job whose `if` does not match is recorded as `skipped`
# and a run of skipped jobs still concludes success. Asking the looser question
# is what passed the commit released as 0.5.0, whose only run that executed
# e2e had failed. See docs/3.3, "Gating on a particular run".
#
# **Which run depends on the environment.** A rehearsal exercises a commit that
# is usually still on a branch, so there is no push-to-`main` run to wait for —
# asking for one blocked the gate for its full twenty minutes and never reached
# the build. And e2e cannot be required of a branch push, because it does not
# run there: requiring it would refuse every rehearsal rather than every other
# one.
if (( IS_RELEASE )); then
  CI_RUN=(--run push:main --require e2e)
else
  CI_RUN=(--run push)
fi
if [[ "${DEPLOY_SKIP_CI:-}" == "1" ]]; then
  echo "==> WARNING: skipping the CI gate (DEPLOY_SKIP_CI=1)"
# `--wait` rather than a bare check: CI takes 3-10 minutes, so deploying
# shortly after a push otherwise refuses with "still in progress" and leaves
# you to run the wait by hand and come back. Blocking here folds that into
# the one command you already typed.
elif ! "$REPO_DIR/scripts/ci-status.sh" --wait \
  "${CI_RUN[@]}" "$TARGET_FULL_SHA"; then
  echo "error: refusing to deploy — see above. Fix CI rather than deploying past it," >&2
  echo "       or set DEPLOY_SKIP_CI=1 if GitHub itself is the problem." >&2
  exit 1
fi
note_gate ci

# The pull request's own run, separately, because it is an independent answer.
# A version branch is merged fast-forward, so the released commit *is* the
# branch tip the PR tested — and for the commit released as 0.5.0 that run had
# failed, which this alone would have refused.
#
# Conditional, because not every change has a pull request: the merge lane
# routinely does not. Absence is therefore a pass, which is the shape that let
# 0.5.0 through, so it is **said out loud** rather than skipped quietly. A line
# reading "no pull-request run" is something you can notice and question; a
# gate that stays silent when it has nothing to check is not.
if (( ! IS_RELEASE )) || [[ "${DEPLOY_SKIP_CI:-}" == "1" ]]; then
  :
# The same query shape ci-status.sh uses, counted here in bash rather than by
# `gh --jq`. Two ways of asking the same question about the same data is how
# they come to disagree — and the count was the only place relying on gh's
# embedded jq, which made this branch the one part of the gate a test could not
# reproduce faithfully.
elif ! printf '%s\n' "$(gh run list --commit "$TARGET_FULL_SHA" --workflow CI --limit 30 \
      --json databaseId,event,headBranch,status,conclusion,url \
      --jq '.[] | [.databaseId, .event, .headBranch, .status, .conclusion, .url] | @tsv' \
      2>/dev/null || true)" | cut -f2 | grep -qx 'pull_request'; then
  echo "==> No pull-request run for this commit — nothing to check there"
elif ! "$REPO_DIR/scripts/ci-status.sh" --run pull_request "$TARGET_FULL_SHA"; then
  echo "error: refusing to deploy — the pull request for this commit did not pass CI." >&2
  echo "       That run is the one that exercises e2e against the branch." >&2
  exit 1
fi
note_gate pull-request

# Ordered before the rehearsal check deliberately. This is an impossibility,
# not a process requirement: no amount of rehearsing makes an image bootable
# against a database it does not understand. Checked second, a rollback
# across a migration was told "rehearse it first", which costs four
# minutes of rebuilding before the deploy refuses anyway. Found in the
# 2026-08-01 rollback drill.
# Refuses to ship an image the live database has already moved past.
#
# Migrations only go forward. sqlx validates, on startup, that every
# migration recorded in the database is one the binary knows about
# (`ignore_missing` is false by default), so an older image meeting a
# newer database fails with `VersionMissing` and **never boots**. Without
# this check that failure arrives after the images are built, transferred
# and swapped in — i.e. as an outage.
#
# The database's own version comes from `/health`'s `schema_version`; the
# target's comes from the migration filenames in that commit's tree, read
# straight out of git so this can run before anything is checked out.
TARGET_SCHEMA="$(git ls-tree --name-only "$TARGET_FULL_SHA" crates/server-game/migrations/ \
  | grep '\.sql$' | sed 's#.*/##' | grep -oE '^[0-9]+' | sort -n | tail -1 | sed 's/^0*//')"
PROD_HEALTH="$(curl -sf --max-time 8 "$TARGET_URL/health" 2>/dev/null || true)"
LIVE_SCHEMA="$(printf '%s' "$PROD_HEALTH" | grep -o '"schema_version":[0-9]*' | cut -d: -f2 || true)"

if [[ -z "$PROD_HEALTH" ]]; then
  echo "==> Note: couldn't reach $TARGET_URL/health, so the schema check was skipped."
elif [[ -z "$LIVE_SCHEMA" ]]; then
  # Every deployment before this field existed. Nothing to compare against,
  # and saying so is better than silently passing a check that never ran.
  echo "==> Note: production reports no schema_version (it predates the field),"
  echo "    so the schema check was skipped. It applies from the next deploy on."
elif (( LIVE_SCHEMA > TARGET_SCHEMA )); then
  echo "error: production's database is at migration $LIVE_SCHEMA, but $TARGET_SHA only knows up to $TARGET_SCHEMA." >&2
  echo "       That image would fail sqlx's startup check and never boot." >&2
  echo "" >&2
  echo "       Migrations don't run backwards. To go back past one, restore the" >&2
  echo "       snapshot taken before the deploy that applied it:" >&2
  echo "         ./scripts/rollback.sh                  # list snapshots and images" >&2
  echo "         ./scripts/rollback.sh <snapshot>       # restore it, then deploy" >&2
  exit 1
else
  echo "==> Schema check passed (database at $LIVE_SCHEMA, $TARGET_SHA knows up to $TARGET_SCHEMA)"
fi
note_gate schema

# Read from the deployed commit's own tree, not the working tree's
# Cargo.toml — on a rollback those are different numbers, and the tag has
# to name the version that actually shipped.
DEPLOYED_VERSION="$(git show "$TARGET_FULL_SHA:Cargo.toml" | grep -m1 '^version' | cut -d'"' -f2 || true)"
if [[ -z "$DEPLOYED_VERSION" ]]; then
  echo "error: couldn't read a version from $TARGET_SHA's Cargo.toml." >&2
  exit 1
fi
note_gate version

# A patch release may not carry functional change — the rule and the reasoning
# are in docs/3.3, "Releases are branches". Checked here, before anything is
# built, so a wrong version number costs a moment rather than a release. The
# check passes whenever it cannot judge (no milestone, no `gh`, no network), so
# it can only ever catch a mistake, never invent one.
if (( IS_RELEASE )); then
  "$REPO_DIR/scripts/check-release-version.sh" "$DEPLOYED_VERSION"
fi

# The milestone is a shipping list, and the deploy closes *everything* in it —
# built or not, tested or not, deliberately deferred or not. So the moment to
# look at its contents is now, before the deploy, not afterwards: reopening an
# issue later leaves one that has already announced a release it was not in.
#
# Two failures inside a week are why this exists rather than being a paragraph
# in docs/3.3. #67 was closed by 0.6.0 while the testing report listed it as
# *Deferred* — the only one of twelve not verified — and it turned out to be
# genuinely broken, needing its own release days later. #151 was caught sitting
# unbuilt in 0.6.1 by hand, with an hour to spare.
#
# The check has two halves, because those two failures are different. An issue
# with **no commit mentioning it** was never built, and that is decidable — so
# it is called out. An issue that was built but not *verified* looks identical
# to one that was, so nothing can decide it: for that half the answer is to show
# the list and make somebody look.
if (( ! IS_RELEASE )); then
  :   # not a release: no milestone will be closed, so nothing to check
elif ! command -v gh > /dev/null; then
  # Said out loud. A check that quietly does not run reads exactly like one
  # that ran and passed — which is the shape that let two earlier gates fail
  # open, and the reason the pull-request gate below announces its own absence.
  echo "==> Milestone $DEPLOYED_VERSION NOT CHECKED — no 'gh' on PATH." >&2
  echo "    Whatever is open in that milestone will be closed by this deploy," >&2
  echo "    unchecked. Read it yourself before continuing." >&2
else
  # Exit status and output kept apart: `|| true` would make "the query failed"
  # indistinguishable from "the milestone is empty", and those want opposite
  # responses.
  MILESTONE_OPEN=""
  # The **issue type** comes back with the title, so the deploy can say what it
  # closed rather than only that it closed something. Available since `gh` 2.94;
  # before that it needed a GraphQL document, which is why this asked for
  # number and title alone.
  if MILESTONE_OPEN="$(gh issue list --milestone "$DEPLOYED_VERSION" --state open \
      --json number,title,issueType \
      --jq '.[] | "\(.number)\t\(.issueType.name // "untyped")\t\(.title)"' 2>&1)"; then
    MILESTONE_QUERY_OK=1
  else
    MILESTONE_QUERY_OK=0
  fi

  if (( ! MILESTONE_QUERY_OK )); then
    echo "==> Milestone $DEPLOYED_VERSION COULD NOT BE READ:" >&2
    printf '    %s\n' "${MILESTONE_OPEN:-(no detail)}" >&2
    echo "    The deploy will still close whatever is in it. Check by hand:" >&2
    echo "        gh issue list --milestone $DEPLOYED_VERSION --state open" >&2
  elif [[ -z "$MILESTONE_OPEN" ]]; then
    echo "==> Milestone $DEPLOYED_VERSION has no open issues — nothing to close"
  else
    echo "==> Milestone $DEPLOYED_VERSION — these will be closed by this deploy:"
    UNBUILT=""
    NOT_PROJECT=""
    while IFS=$'\t' read -r NUM KIND TITLE; do
      [[ -z "$NUM" ]] && continue
      # Any commit reachable from what is being shipped that names the issue.
      # `Refs #N` and `Closes #N` both count.
      #
      # `rev-list --count` rather than `git log … | grep -q .`: the pipe was the
      # defect. `grep -q` exits on the first match, `git log` takes SIGPIPE, and
      # under `set -o pipefail` the pipeline reports failure — so an issue that
      # *is* mentioned reported NO COMMIT MENTIONS THIS as soon as the history
      # was long enough. Measured on #174, which fifty-eight commits mention:
      # status 141. No pipe, no race, and a count is more use than a boolean.
      MENTIONS="$(commits_mentioning "$TARGET_FULL_SHA" "$NUM")"
      if (( MENTIONS > 0 )); then
        printf '    #%-5s %-12s %s   (%s commits)\n' "$NUM" "$KIND" "${TITLE:0:52}" "$MENTIONS"
      else
        # A package split out after its commits landed carries the parent's
        # number and cannot be made to carry its own. 0.8.0 stopped at this
        # prompt over #373, built by `1036e1c` saying `Refs #297`, three lines
        # above a manifest marking that same commit as reaching the image.
        #
        # **The parent's commits are a fact here, not credit.** Crediting them
        # was tried on 2026-09-10 and was wrong: a parent with two packages
        # cannot say which of them a commit belongs to, so #363 — delivery 2 of
        # #301, unstarted — read as merged on delivery 1's commits. A guess that
        # exonerates is worse than a prompt, because this prompt is the last
        # thing between an unbuilt issue and a milestone that closes it.
        #
        # So it still counts as unbuilt and the operator gets the one fact that
        # answers the prompt in a second. #375.
        PAR="$(parent_of "$NUM")"
        PARMENTIONS=0
        [[ -n "$PAR" ]] && PARMENTIONS="$(commits_mentioning "$TARGET_FULL_SHA" "$PAR")"
        if [[ -n "$PAR" ]] && (( PARMENTIONS > 0 )); then
          printf '    #%-5s %-12s %s   <-- NO COMMIT MENTIONS THIS (parent #%s has %s)\n' \
            "$NUM" "$KIND" "${TITLE:0:52}" "$PAR" "$PARMENTIONS"
        else
          printf '    #%-5s %-12s %s   <-- NO COMMIT MENTIONS THIS\n' "$NUM" "$KIND" "${TITLE:0:52}"
        fi
        UNBUILT="$UNBUILT #$NUM"
      fi
      # A milestone is a release, and a release is made of project deliveries —
      # so a milestone should contain projects and nothing else (docs/3.6 §1.1).
      # A warning rather than a refusal: the operator's intent stays
      # authoritative, and the convention stops being one nobody checks.
      [[ "$KIND" == "Project" ]] || NOT_PROJECT="$NOT_PROJECT #$NUM($KIND)"
    done <<< "$MILESTONE_OPEN"

    if [[ -n "$NOT_PROJECT" ]]; then
      echo
      echo "    Not a project, and a milestone is made of project deliveries:$NOT_PROJECT" >&2
      echo "    A requirement is closed when it folds into a project, so it" >&2
      echo "    should not be carrying a milestone at all — docs/3.6 §1.1." >&2
    fi

    # The mirror image of the check above: that one finds an issue in the
    # milestone that no commit mentions — in the release list, not in the
    # release. This finds one the commits mention that is not in the milestone —
    # in the release, not in the list. See placeholder_shipping().
    PLACEHOLDER_SHIPPING="$(placeholder_shipping "$TARGET_FULL_SHA")"
    [[ -n "$PLACEHOLDER_SHIPPING" ]] && printf '%s\n' "$PLACEHOLDER_SHIPPING"

    if [[ -n "$PLACEHOLDER_SHIPPING" ]]; then
      echo
      echo "    Shipping in this release but filed under a placeholder:$PLACEHOLDER_SHIPPING" >&2
      echo "    A placeholder milestone is never the one a deploy closes, so these" >&2
      echo "    would ship and then stop being tracked — not closed, not announced," >&2
      echo "    not deferred. Move them to $DEPLOYED_VERSION, or out of the" >&2
      echo "    placeholder if they are not in this release." >&2
    fi

    if [[ -n "$UNBUILT" ]]; then
      echo
      echo "    Nothing in this release mentions:$UNBUILT" >&2
      echo "    An issue with no commit was not built. Move it to another" >&2
      echo "    milestone before deploying, or it will be settled as though" >&2
      echo "    it shipped: a Project is advanced to Post-deployment and left" >&2
      echo "    open for a review it cannot answer; anything else is closed." >&2
    fi

    # Gates-only exists to exercise refusals cheaply, and a prompt it cannot
    # answer would hang it — the same trap the tooling-branch guard hit.
    if [[ "${DEPLOY_GATES_ONLY:-}" == "1" ]]; then
      echo "    (gates only — not asking)"
    elif [[ -n "$UNBUILT" || -n "$PLACEHOLDER_SHIPPING" ]]; then
      # Asked rather than refused, for the placeholder half as much as the other:
      # a `Refs #N` in passing is not a claim that #N shipped, so a false positive
      # is plausible — and a gate that cries wolf on the deploy path is one people
      # learn to bypass, with DEPLOY_EMERGENCY already there to do it with.
      if [[ ! -t 0 ]]; then
        echo "error: refusing — the milestone needs attention and there is no terminal to confirm at." >&2
        exit 1
      fi
      read -r -p "    Continue anyway? [y/N] " REPLY_MILESTONE
      if [[ "$REPLY_MILESTONE" != "y" && "$REPLY_MILESTONE" != "Y" ]]; then
        echo "    Stopped. Move them out of $DEPLOYED_VERSION and run again." >&2
        exit 1
      fi
    fi
  fi
fi
note_gate milestone

# Refuses to ship a commit that was never actually exercised on the rehearsal host —
# a passing `cargo test` only proves the code compiles and unit-tests
# clean, not that it boots/migrates cleanly in a real container. Without
# this check, rehearsing commit A and then committing a "quick
# fix" B before deploying would silently ship B untested — easy to do
# without noticing, since deploy.sh has no other way to know the rehearsal host
# wasn't re-run. See docs/3.3-testing-ci-and-release.md.
if [[ "$DEPLOY_REF" == "HEAD" ]]; then
  STAGING_CMD="./scripts/deploy-rehearsal.sh"
else
  STAGING_CMD="./scripts/deploy-rehearsal.sh $DEPLOY_REF"
fi
# Gating a rehearsal on another environment is circular — the rehearsal is
# what the gate is *for*.
#
# **Preview used to be deliberately not a gate**, on the argument that a gate
# can check the bits were present somewhere and never that anybody looked at
# them and was happy. That paragraph outlived the code: a preview gate was
# added below and this comment sat directly above it, saying the opposite, and
# `note_gate preview` counts it. The argument survives as the honest limit on
# what the gate proves — see the block below — rather than as a reason it does
# not exist.
if (( ! IS_RELEASE )); then
  echo "==> Skipping the rehearsal gate: this deploy is the rehearsal"
else
# The user-testing gate — and it is worth being honest about what it can do.
# It proves this commit was *deployed* to preview. It cannot prove anybody
# looked at it, and nothing else in the pipeline can either: whether a person
# formed a judgement is not observable from here. So this is a prompt, not a
# proof, and the only one available for the question.
#
# That is also the argument against having it. A technical change may be
# better tested elsewhere, and user testing could reasonably happen against a
# branch — which the process does not currently allow, since preview deploys
# HEAD. Both are reasons to skip it deliberately, not reasons to drop it:
# skipping is visible, and absence is not.
#
# Skippable, because some changes have nothing a person can look at — release
# tooling, most obviously, which is exactly the kind of change that cannot be
# rehearsed either. The variable says "there was nothing to see", not "I did
# not look", so it is named for the gate rather than for the inconvenience.
if [[ -n "$EMERGENCY" ]]; then
  echo "==> Skipping the preview gate (emergency)"
elif (( IS_RELEASE )) && [[ "${DEPLOY_SKIP_PREVIEW:-}" != "1" ]]; then
  PREVIEW_HEALTH="$(curl -sf --max-time 5 "$PREVIEW_URL/health" 2>/dev/null || true)"
  PREVIEW_VERSION="$(printf '%s' "$PREVIEW_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  PREVIEW_SHA="${PREVIEW_VERSION#*+}"
  if [[ -z "$PREVIEW_VERSION" ]]; then
    echo "error: preview ($PREVIEW_URL) isn't running — look at this commit there first:" >&2
    echo "           ./scripts/deploy-preview.sh" >&2
    echo "       DEPLOY_SKIP_PREVIEW=1 if there is nothing for a person to look at." >&2
    exit 1
  elif [[ "$PREVIEW_SHA" != "$TARGET_SHA" ]]; then
    echo "error: preview is running commit $PREVIEW_SHA, not $TARGET_SHA ($DEPLOY_REF)." >&2
    echo "       Look at this commit there first: ./scripts/deploy-preview.sh" >&2
    echo "       DEPLOY_SKIP_PREVIEW=1 if there is nothing for a person to look at." >&2
    exit 1
  fi
fi
note_gate preview

if [[ -n "$EMERGENCY" ]]; then
  echo "==> Skipping the rehearsal gate (emergency)"
else
STAGING_HEALTH="$(curl -sf --max-time 5 "$REHEARSAL_URL/health" 2>/dev/null || true)"
# `|| true` on every one of these: `grep` exits 1 when it matches nothing,
# and under `set -o pipefail` that kills the assignment outright — so the
# "is it empty" branch written to handle exactly that case never runs, and
# the script dies with no message at all. This is not hypothetical; it
# aborted a production deploy silently.
STAGING_VERSION="$(printf '%s' "$STAGING_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
STAGING_SHA="${STAGING_VERSION#*+}"
if [[ -z "$STAGING_VERSION" ]]; then
  echo "error: the rehearsal host ($REHEARSAL_URL) isn't reachable — rehearse this commit first: $STAGING_CMD" >&2
  exit 1
elif [[ "$STAGING_SHA" == "$STAGING_VERSION" ]]; then
  echo "error: the rehearsal host is running $STAGING_VERSION, which has no commit id — was it deployed via deploy-rehearsal.sh?" >&2
  exit 1
elif [[ "$STAGING_SHA" != "$TARGET_SHA" ]]; then
  echo "error: the rehearsal host is running commit $STAGING_SHA, not $TARGET_SHA ($DEPLOY_REF) — rehearse it first: $STAGING_CMD" >&2
  exit 1
fi
note_gate rehearsal
echo "==> Rehearsal host confirmed running this commit ($TARGET_SHA) — proceeding"
fi
fi

# Every gate has now had its say, and nothing has been changed yet. That makes
# this the one point where the checks can be exercised without deploying —
# which is what `DEPLOY_GATES_ONLY=1` is for, and what makes
# `scripts/tests/deploy.test.sh` possible at all.
#
# Until it existed, these gates were only ever run by deploying, so the branch
# where each says **no** almost never ran: nobody rehearses a deploy against a
# commit they expect to be refused. Two gates had already failed open for
# exactly that reason, and a third (#100) refused every rehearsal for a day
# before a person tripped over it.
#
# Useful by hand too — "would this deploy be allowed?" is worth being able to
# ask without finding out the expensive way.
# The checklist. A gate that did not run is a gate that did not pass, whatever
# the absence of complaints suggests.
# Which gates are expected depends on what kind of deploy this is, and saying so
# explicitly is half the value: an emergency skipping preview and rehearsal is a
# decision, and it now has to be written down rather than inferred from the fact
# that nothing complained.
if (( ! IS_RELEASE )); then
  # A rehearsal has no preview to compare, no milestone to close, no
  # pull-request run to consult, and skips its own gate — it *is* the rehearsal.
  GATES_EXPECTED="on-remote ci schema version"
elif [[ -n "$EMERGENCY" ]]; then
  # Preview and rehearsal are exactly what an emergency gives up. Everything
  # else still applies, which is the difference between an emergency and a
  # free-for-all.
  GATES_EXPECTED="on-remote ci pull-request schema version milestone"
else
  GATES_EXPECTED="on-remote ci pull-request schema version milestone preview rehearsal"
fi
echo "==> Gates run:$GATES_RUN"
GATES_MISSING=""
for GATE in $GATES_EXPECTED; do
  case " $GATES_RUN " in
    *" $GATE "*) ;;
    *) GATES_MISSING="$GATES_MISSING $GATE" ;;
  esac
done
if [[ -n "$GATES_MISSING" ]]; then
  echo "error: refusing to deploy — these gates did not run:$GATES_MISSING" >&2
  echo "       Every check must be seen to have happened, not merely to have" >&2
  echo "       raised no objection. This is a bug in deploy.sh, not in the" >&2
  echo "       commit being deployed." >&2
  exit 1
fi

if [[ "${DEPLOY_GATES_ONLY:-}" == "1" ]]; then
  echo "==> Gates only: every check passed, stopping before anything is built"
  exit 0
fi

# Prove the key works before the build, which is the expensive part — see
# ssh-preflight.sh for why a locked key otherwise fails three minutes from now
# with a message that does not mention keys.
#
# Deliberately *after* the gates rather than first. The gates are seconds of
# network checks and are what `scripts/tests/deploy.test.sh` exercises, with
# fake keys against no reachable host; a preflight above them aborts the very
# logic under test. Below the gates-only exit it also stays out of the way of
# "would this deploy be allowed?", which is a question about policy rather
# than connectivity.
# shellcheck source=scripts/ssh-preflight.sh
source "$(dirname "$0")/ssh-preflight.sh"
require_ssh_access "$DEPLOY_SSH_KEY" "$REMOTE" || exit 1

# The fresh checkout. A throwaway `git worktree` rather than checking $REF
# out here: it leaves the real working copy (branch, staged and unstaged
# changes) completely untouched, which is what makes it safe to deploy an
# older commit in the middle of unrelated work.
#
# The compose file comes from the worktree too, so the runtime
# configuration shipped to the VM is the one that belongs to the code
# being shipped — on a rollback, that matters as much as the images do.
WORKTREE_DIR="$(mktemp -d /tmp/tile-lite-elite-deploy-worktree-XXXXXX)"
cleanup() {
  # The artefact is deliberately **not** removed here: it is a cache keyed by
  # commit, and the next environment deploying that commit is meant to find it.
  # A half-written one cannot survive, because build_artifact writes through
  # `.partial` and only renames when the save completed.
  rm -f "$(artifact_path "$TARGET_FULL_SHA").partial"
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT
# rmdir first: `git worktree add` refuses to target a directory mktemp
# already created, even an empty one.
rmdir "$WORKTREE_DIR"
git worktree add --detach "$WORKTREE_DIR" "$TARGET_FULL_SHA" >/dev/null

# Baked into both binaries as SemVer build metadata (e.g. `0.2.0+a1c9f02`) —
# see docs/4.1-configuration.md's "Versioning" section.
export TILE_LITE_ELITE_BUILD_ID="$TARGET_SHA"

# `-f <worktree>/docker-compose.yml` also sets the project directory to the
# worktree, so each service's `context: .` resolves to the checkout rather
# than to this repo. The image tags are unaffected: they derive from the
# `name:` pinned inside the compose file, not from the directory.
build_artifact "$TARGET_FULL_SHA" "$WORKTREE_DIR"
ARTIFACT_TAR="$(artifact_path "$TARGET_FULL_SHA")"

# Read before every deploy, not only after a build, so the digest printed here
# is the one being shipped. Rehearsal and production print the same line for
# one commit, which is the evidence R1 is about — and it goes in the delivery
# log, where two rows can be compared afterwards.
ARTIFACT_DIGEST="$(verify_artifact "$ARTIFACT_TAR")"
echo "    $(du -h "$ARTIFACT_TAR" | cut -f1) compressed, sha256:${ARTIFACT_DIGEST:0:12}"

# What is in this build, beside the bytes it describes (#288 R1, R2). Written
# after the digest is known and before anything is shipped, so the record exists
# whether or not the rest of the deploy succeeds — which is the case #310 was
# lost to.
MANIFEST="$(write_manifest "$TARGET_FULL_SHA" "$ARTIFACT_DIGEST")"
echo "    manifest: $(basename "$MANIFEST") — $(grep -c '^  ' "$MANIFEST" || echo 0) lines of contents"

echo "==> Transferring to $DEPLOY_HOST"
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_REMOTE_DIR"
scp "${SCP_OPTS[@]}" "$ARTIFACT_TAR" "$WORKTREE_DIR/docker-compose.yml" "$REMOTE:$DEPLOY_REMOTE_DIR/"

REMOTE_TAR_NAME="$(basename "$ARTIFACT_TAR")"
SNAPSHOT_NAME="pre-$DEPLOYED_VERSION-$TARGET_SHA-$(date -u +%Y%m%dT%H%M%SZ).tgz"

# Rolls production back to the images and database it had a moment ago.
# Delegated to rollback.sh so the automatic recovery below and the one you
# would run by hand are the same code, and cannot drift apart. `--yes`
# because at these call sites the deploy has already failed and the
# confirmation prompt would only stand between a broken site and its fix.
roll_back() {
  echo "==> Rolling back to the pre-deploy state" >&2
  if "$REPO_DIR/scripts/rollback.sh" --yes "$SNAPSHOT_NAME"; then
    echo "==> Rolled back. Production is as it was before this deploy." >&2
  else
    echo "error: THE ROLLBACK ALSO FAILED. Production may be down." >&2
    echo "       Snapshot to restore by hand: $SNAPSHOT_NAME" >&2
    echo "       ssh in and check: docker compose logs --tail=50 server" >&2
  fi
}

echo "==> Loading images and snapshotting the database"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR

    # Retag the live images as :previous *before* loading the new ones.
    # Without this the old image becomes dangling the moment :latest moves,
    # and the prune below destroys it — which is why rolling back used to
    # mean a full local rebuild and re-transfer for an image that had been
    # sitting here minutes earlier. Two generations, ~300MB, on a disk
    # that is 13% used.
    docker image tag tile-lite-elite-server:latest tile-lite-elite-server:previous 2>/dev/null || true
    docker image tag tile-lite-elite-web:latest tile-lite-elite-web:previous 2>/dev/null || true

    gunzip -c $REMOTE_TAR_NAME | docker load
    rm -f $REMOTE_TAR_NAME
    mkdir -p snapshots

    # Stop the server before snapshotting. The database is SQLite in WAL
    # mode, so tarring it live can capture a torn state — a main file
    # without the WAL entry that completes it. The container is about to be
    # recreated anyway, so quiescing it here costs no extra downtime and
    # makes the snapshot trustworthy.
    docker compose stop server > /dev/null

    # Uses the app's own image purely because it is already present and is
    # debian-slim, so it has tar — no extra pull onto a 1GB VM. The volume
    # is mounted read-only; this only ever reads.
    docker run --rm \
        -v tile-lite-elite-data:/data:ro \
        -v \"\$PWD/snapshots\":/snapshots \
        --entrypoint tar \
        tile-lite-elite-server:latest \
        czf /snapshots/$SNAPSHOT_NAME -C /data .
    echo \"    snapshot: \$(du -h snapshots/$SNAPSHOT_NAME | cut -f1)\"
"

# Apply the schema change on its own, before the new build becomes the
# server. Migrations otherwise run as a side effect of startup, which fuses
# "does the schema change work" with "does the new version serve traffic" —
# and fused, a failing migration is an outage, because the old container has
# already been replaced and the new one just exits and restarts. Asked
# separately, the old code is still installed and the deploy simply stops.
#
# `compose run` rather than a bare `docker run` so this gets the service's
# real volume mount and environment, exactly as the server would.
#
# Wrapped in a timeout because the failure mode of an image that *doesn't*
# understand `--migrate-only` is not an error — the flag is ignored, the
# server starts normally, and it runs forever. Found the hard way against a
# image built before the flag existed: the command simply never
# returned. A deploy that hangs is worse than one that fails, so cap it.
echo "==> Applying migrations (separately, so a failure here is not an outage)"
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    timeout 300 docker compose run --rm --no-deps server --migrate-only
"; then
  echo "error: migrations failed (or timed out) — this build's schema change does not apply" >&2
  echo "       to production's database, or the image ignored --migrate-only and hung." >&2
  echo "       Nothing was swapped in. SQLite wraps each migration in a transaction," >&2
  echo "       so the database is unchanged, and the previous version is still installed." >&2
  echo "       Restoring the snapshot and restarting it now, to be certain." >&2
  roll_back
  exit 1
fi

echo "==> Starting the new version"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    docker compose up -d

    # Prunes the image the *previous* deploy had tagged :previous, which
    # this deploy's retag just displaced. Keeps exactly two generations.
    docker image prune -f > /dev/null

    # \`ls -t\` is safe here: these names are generated by this script and
    # contain no whitespace.
    ls -1t snapshots/*.tgz 2>/dev/null | tail -n +$((SNAPSHOT_KEEP + 1)) | xargs -r rm -f
    echo \"    snapshots kept: \$(ls -1 snapshots/*.tgz | wc -l)\"
"

# The smoke test. End to end on purpose — public DNS, TLS, Caddy, and the
# server behind it — because that is the path a player takes, and each hop
# is something a deploy can break without the container itself looking
# unhealthy. Checking the version rather than just a 200 is what makes it a
# test of *this* deploy: a stale container still answering would otherwise
# pass.
EXPECTED_VERSION="$DEPLOYED_VERSION+$TARGET_SHA"
echo "==> Smoke testing $TARGET_URL (expecting $EXPECTED_VERSION)"
SMOKE_OK=0
for _ in $(seq 1 30); do
  LIVE_HEALTH="$(curl -sf --max-time 5 "$TARGET_URL/health" 2>/dev/null || true)"
  # Unreachable /health is the normal state for the first few seconds here,
  # so this must survive matching nothing rather than abort the retry loop.
  LIVE_APP="$(printf '%s' "$LIVE_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  if [[ "$LIVE_APP" == "$EXPECTED_VERSION" ]]; then
    SMOKE_OK=1
    echo "    $LIVE_HEALTH"
    break
  fi
  sleep 2
done

if (( SMOKE_OK == 0 )); then
  echo "error: production did not come up healthy on $EXPECTED_VERSION within 60s." >&2
  echo "       last /health: ${LIVE_HEALTH:-<no response>}" >&2
  roll_back
  exit 1
fi


echo "==> Ensuring the 'sa' alias for tile-lite-elite-admin is set up and current on the VM"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    # Drop any existing 'alias sa=' line first, then re-append the current
    # definition. A stale line (e.g. an old deploy dir, or the pre-rename
    # admin binary name) used to survive because the previous logic only
    # appended when *no* 'alias sa=' line existed at all — so an out-of-date
    # value was never refreshed. Delete-then-append converges to exactly one
    # correct line whether the alias was absent, current, or stale.
    sed -i '/alias sa=/d' ~/.bashrc 2>/dev/null || true
    echo \"alias sa='docker compose -f ~/$DEPLOY_REMOTE_DIR/docker-compose.yml exec server tile-lite-elite-admin'\" >> ~/.bashrc \
        || echo \"    (warning: could not set up the 'sa' alias for tile-lite-elite-admin)\"
"

# --- Past this line, production is live -------------------------------------
#
# Everything from here is post-deploy: it records what happened rather than
# making it happen. Each step goes through `post_deploy`, so a failure is
# reported and the run continues. See its definition above for why.

# Stamp the deployed commit in git history. A tag rather than a commit: it
# points at the *thing that shipped*, not at the bump that follows it, and
# it costs no history. `git tag --list 'prod-*'` is then the deployment log,
# `git describe --tags` on any commit says which release it came after, and
# `git log prod-0.4.12..prod-0.4.13` is exactly what a given deploy carried.
#
# Annotated (-a), so it records who deployed and when as a real object
# rather than a bare pointer. Named explicitly against the deployed SHA, so
# it lands correctly regardless of the bump below.
DEPLOY_TAG="prod-$DEPLOYED_VERSION"
if (( ! IS_RELEASE )); then
  # No tag, and DEPLOY_TAG is still referenced by the messages below, so it
  # keeps a readable value rather than being unset under `set -u`.
  DEPLOY_TAG="(none — $DEPLOY_ENV deploy, not a release)"
  echo "==> No prod-* tag: this was a $DEPLOY_ENV deploy, not a release"
elif git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$DEPLOY_TAG" > /dev/null; then
  # Same version deployed twice — a redeploy, a rollback to a release that
  # already carries its tag, or a bump that didn't happen. Keep both rather
  # than moving the tag: a force-moved tag loses the record of the earlier
  # deploy, which is the one thing this exists to keep.
  DEPLOY_TAG="$DEPLOY_TAG-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Tag exists already; using $DEPLOY_TAG"
fi
if (( IS_RELEASE )); then
  if post_deploy "tagging $DEPLOY_TAG" "git tag -a $DEPLOY_TAG $TARGET_SHA && git push origin $DEPLOY_TAG" \
       git -C "$REPO_DIR" tag -a "$DEPLOY_TAG" "$TARGET_FULL_SHA" \
         -m "Deployed to production $(date -u +%Y-%m-%dT%H:%MZ) from $TARGET_SHA"; then
    post_deploy "pushing $DEPLOY_TAG" "git push origin $DEPLOY_TAG" git -C "$REPO_DIR" push --quiet origin "$DEPLOY_TAG" \
      && echo "==> Tagged $DEPLOY_TAG"
  fi

  # The public changelog for this version, generated by GitHub. See §3.3.1 of
  # docs/3.3 for why it does not replace the delivery log.
  post_deploy "publishing the release notes" "gh release create $DEPLOY_TAG --generate-notes" publish_release "$DEPLOY_TAG" "$DEPLOYED_VERSION" || true
fi

# The working tree moves one patch ahead of what was just shipped, so no
# later commit is ever built carrying a version number already live. This
# used to be a step you had to remember (docs/3.3, an explicit final step) — but it is
# only ever correct immediately after a successful deploy, which is exactly
# here, and nowhere else.
#
# Only when rolling *forward*, though. After a rollback the branch tip is
# already ahead of what's now in production, and bumping it again would
# claim a release that never happened — the version to move on from is the
# newest one, not the one just redeployed.
CURRENT_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
BRANCH_TIP="$(git -C "$REPO_DIR" rev-parse HEAD)"
NEXT_VERSION="$(printf '%s' "$DEPLOYED_VERSION" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"

if (( ! IS_RELEASE )); then
  echo "==> No version bump: a $DEPLOY_ENV deploy does not consume a version"
elif [[ "${DEPLOY_SKIP_BUMP:-}" == "1" ]]; then
  echo "==> Skipping the version bump (DEPLOY_SKIP_BUMP=1) — production is on $DEPLOYED_VERSION"
elif [[ "$BRANCH_TIP" != "$TARGET_FULL_SHA" ]]; then
  echo "==> Deployed $DEPLOYED_VERSION from an earlier commit, so leaving the version alone."
  echo "    Your branch ($CURRENT_BRANCH) is already ahead of what's now in production."
elif [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "==> Detached HEAD, so leaving the version alone — nothing to bump onto."
elif ! git -C "$REPO_DIR" diff --quiet -- Cargo.toml Cargo.lock; then
  echo "==> Cargo.toml/Cargo.lock have uncommitted edits, so leaving the version alone." >&2
  echo "    Bump to $NEXT_VERSION by hand once they're committed." >&2
else
  echo "==> Bumping the working tree to $NEXT_VERSION (production now holds $DEPLOYED_VERSION)"
  sed -i "0,/^version = \"$DEPLOYED_VERSION\"/s//version = \"$NEXT_VERSION\"/" "$REPO_DIR/Cargo.toml"
  # Refreshes Cargo.lock's workspace versions so the bump commit is complete.
  ( cd "$REPO_DIR" && cargo check --workspace --quiet > /dev/null 2>&1 || true )
  git -C "$REPO_DIR" add Cargo.toml Cargo.lock
  # Read API_VERSION from the commit, not the working tree. This commit
  # carries only Cargo.toml/Cargo.lock, so its api/src/lib.rs is HEAD's —
  # and check-commit-stamp.sh validates the stamp against the commit's own
  # tree. An uncommitted edit to API_VERSION would otherwise produce a
  # stamp that fails its own check.
  # One parser, shared with check-commit-stamp.sh and tested in
  # scripts/tests/ — rustfmt wraps this declaration once the numbers grow,
  # and both readers assumed one line. It exits non-zero rather than
  # printing nothing, so a version that cannot be read stops the bump
  # instead of writing a stamp its own checker would reject.
  BUMP_API="$(git -C "$REPO_DIR" show HEAD:crates/api/src/lib.rs \
    | "$(dirname "$0")/read-api-version.sh")"
  if post_deploy "the version bump commit" "Cargo.toml is staged at $NEXT_VERSION — commit it, --no-verify if the image rule refuses (see #316)" \
       git -C "$REPO_DIR" commit --quiet \
         -m "app $NEXT_VERSION api $BUMP_API: bump dev version following production release" \
         -m "Production now runs $DEPLOYED_VERSION+$TARGET_SHA."; then
    post_deploy "the version bump push" "git push origin $CURRENT_BRANCH" \
      git -C "$REPO_DIR" push --quiet origin "$CURRENT_BRANCH" \
      && echo "    committed and pushed"
  else
    echo "    the bump is staged but not committed — commit it by hand" >&2
  fi
fi

# Closes the milestone this release delivered, and opens the next one.
#
# GitHub's `Closes #N` fires when a commit reaches the default branch, which
# — with no branching here — is the moment it is *written*, not the moment
# it ships. That marked issues done while they sat unreleased, which is
# exactly what "track a change through to production" needs to distinguish.
# So commits say `Refs #N`, issue state means "work done", and the milestone
# means "in production". This is the step that makes the second one true.
#
# Rolling forward only, same test as the version bump: a rollback deploys an
# older version whose milestone closed long ago.
#
# Best-effort throughout. A GitHub hiccup must not fail a deploy that has
# already succeeded — production is live either way, and the worst case is a
# milestone closed by hand.
# Close what shipped, open what is next — or say why neither happened.
post_deploy "settling the milestone" "close milestone $DEPLOYED_VERSION on GitHub, open the next, and move its projects to Post-deployment" settle_milestone || true

# An emergency change is retrospectively reviewed, not unreviewed. The issue is
# raised here rather than printed as a command to run later, because a reminder
# issued at the worst moment of the week is a reminder that does not happen —
# and without the review the emergency path quietly becomes the normal one.
if [[ -n "$EMERGENCY" ]] && (( IS_RELEASE )); then
  echo
  echo "==> Emergency deploy — gates bypassed:"
  echo "        preview      this commit was never stood up for anyone to look at"
  echo "        rehearsal    the release mechanism was not exercised first"
  echo "    Everything else was checked, CI included."
  if command -v gh > /dev/null; then
    EMERGENCY_BODY="$(cat <<BODY
Production was deployed outside the normal path.

| | |
| --- | --- |
| version | \`$DEPLOYED_VERSION+$TARGET_SHA\` |
| tag | \`$DEPLOY_TAG\` |
| when | $(date -u '+%Y-%m-%d %H:%M UTC') |
| reason given | $EMERGENCY |

**Bypassed:** the preview gate, so nobody looked at this commit standing up;
and the rehearsal gate, so the release mechanism was not exercised against it
before production was.

**Not bypassed:** CI including e2e, the commit being on a remote branch, the
schema check, and the version checks.

The milestone was deliberately not closed — that would claim a scope completed
the normal process. Close what actually shipped by hand.

## To do

- [ ] Confirm production is behaving, beyond the deploy's own smoke test
- [ ] Say what the underlying problem was, separately from the fix — restoring
      service and understanding the cause are different questions
- [ ] Raise the normal change that makes this unnecessary next time
- [ ] Close the milestone and issues this release actually delivered
- [ ] Triage this issue: it has no type or lane yet, deliberately, because
      what it turns into is a judgement

Raised automatically by \`deploy.sh\`.
BODY
)"
    if gh issue create --title "Emergency deploy of $DEPLOYED_VERSION — review what was bypassed" \
      --body "$EMERGENCY_BODY" > /dev/null 2>&1; then
      echo "    raised a retrospective issue — review it before this is forgotten"
    else
      echo "    warning: could not raise the retrospective issue — raise one by hand" >&2
    fi
  fi
  echo
fi

# Only after a deploy has succeeded: a failed one may be about to be retried,
# and the artefact it would reuse is the point.
prune_artifacts

post_deploy "the plan/build disagreement report" "read artifacts/$TARGET_FULL_SHA.manifest and compare with milestone $DEPLOYED_VERSION" \
  report_plan_disagreement "$TARGET_FULL_SHA" "$DEPLOYED_VERSION" || true
post_deploy "the release-check announcement" "gh issue list --label 'Release Check' --state open — those checks are now answerable" announce_release_checks "$IS_RELEASE" "$DEPLOY_ENV" || true

echo "==> Done — https://$DEPLOY_HOST.sslip.io (or your configured hostname)"

# The exit status says which world you are in; the line above it says what
# happened. D46 (#327): 1 is fatal and nothing reached users, 3 is a non-fatal
# error where the run went wrong and continued. Owner, 2026-09-05: *"If there
# is an error, it should return non-zero. We would then look at what the error
# was. If it returns zero we might not even look."*
if (( ${#POST_DEPLOY_FAILED[@]} > 0 )); then
  echo "" >&2
  echo "==> production is live on $DEPLOYED_VERSION+$TARGET_SHA, and ${#POST_DEPLOY_FAILED[@]} step(s) after it failed:" >&2
  printf '      %s\n' "${POST_DEPLOY_FAILED[@]}" >&2
  echo "    The deploy succeeded — these are the steps that record it, with what each needs." >&2
  exit 3
fi
