#!/usr/bin/env bash
set -euo pipefail

# check-release-version.sh — is the version about to be released the right
# *kind* of version for what is in it?
#
# A patch release may not carry functional change. The rule lives in
# docs/3.3-testing-ci-and-release.md ("Releases are branches"): any
# `major-function` or `minor-function` issue in the scope makes it a minor,
# and a minor is branched to rather than bumped into.
#
# This checks rather than decides, deliberately. The version is chosen when the
# release branch is created, with the scope in front of whoever chose it —
# earlier, and by someone who knows more, than any inference here could manage.
# What the choice needs is something that notices when it was wrong, which is
# the failure the old "edit Cargo.toml yourself afterwards" rule never got:
# every functional release the project shipped went out as a patch, and nothing
# said so.
#
# Usage:
#   ./scripts/check-release-version.sh 0.4.26
#   ./scripts/check-release-version.sh 0.4.26 0.4.25   # explicit predecessor
#
# Exit 0 if the version is fine or cannot be judged, 1 if it is wrong.
#
# **It never fails for want of information.** No milestone, no previous release,
# no `gh`, no network — all of those print why and pass. A release must not be
# blocked because GitHub is unreachable; the check exists to catch a mistake,
# not to add a dependency to shipping.

FUNCTIONAL_LABELS='major-function|minor-function'

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: check-release-version.sh <version> [previous-version]" >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: '$VERSION' is not an X.Y.Z version" >&2
  exit 2
fi
this_major="${BASH_REMATCH[1]}"
this_minor="${BASH_REMATCH[2]}"
this_patch="${BASH_REMATCH[3]}"

# The predecessor: given, or the newest `prod-X.Y.Z` tag. `|| true` on both the
# tag listing and the sort, because an unguarded pipeline that matches nothing
# exits non-zero under `set -o pipefail` and would abort a deploy — which has
# happened twice on this project.
PREVIOUS="${2:-}"
if [[ -z "$PREVIOUS" ]]; then
  PREVIOUS="$(git tag --list 'prod-[0-9]*' 2>/dev/null \
    | sed 's/^prod-//' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1 || true)"
fi

if [[ -z "$PREVIOUS" ]]; then
  echo "check-release-version: no previous release to compare against — skipping"
  exit 0
fi

if [[ ! "$PREVIOUS" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "check-release-version: previous release '$PREVIOUS' is not an X.Y.Z version — skipping"
  exit 0
fi
prev_major="${BASH_REMATCH[1]}"
prev_minor="${BASH_REMATCH[2]}"

# Only a patch release can be wrong in the way this looks for. A minor or major
# release is allowed to contain fixes; a patch release is not allowed to contain
# functionality.
if [[ "$this_major" != "$prev_major" || "$this_minor" != "$prev_minor" ]]; then
  echo "check-release-version: $VERSION is a minor or major release — functional change is expected"
  exit 0
fi
: "$this_patch"

if ! command -v gh > /dev/null 2>&1; then
  echo "check-release-version: gh not available — skipping"
  exit 0
fi

# Milestones are named for the version they ship. `|| true` so an API failure,
# an expired token or no network prints nothing and falls through to the skip
# below rather than aborting.
ISSUES="$(gh api "repos/:owner/:repo/issues?milestone=*&state=all&per_page=100" \
  --jq "[.[] | select(.milestone.title == \"$VERSION\")
          | select([.labels[].name] | any(test(\"^($FUNCTIONAL_LABELS)\$\")))
          | \"#\(.number) \(.title)\"] | .[]" 2>/dev/null || true)"

if [[ -z "$ISSUES" ]]; then
  echo "check-release-version: nothing functional in milestone $VERSION — a patch release is right"
  exit 0
fi

echo "check-release-version: $VERSION is a patch release, but its milestone carries functional change:" >&2
printf '  %s\n' "$ISSUES" >&2
cat >&2 <<EOF

A patch release may not carry functional change. Either:

  - this belongs on a minor release branch — see docs/3.3,
    "Releases are branches"; or
  - the labels are wrong, and these are fixes rather than functionality.

Nothing here is automatic on purpose: which of those it is, is a judgement.
EOF
exit 1
