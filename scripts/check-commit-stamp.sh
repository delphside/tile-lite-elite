#!/usr/bin/env bash
set -euo pipefail

# check-commit-stamp.sh — Every commit subject must carry the app and api
# versions, and they must be true of the tree at that commit.
#
# The convention is documented in docs/3.3-testing-ci-and-release.md
# ("Version numbers: which to bump, and when"):
#
#   app <X.Y.Z> api <M.N>: <subject>
#
# Both failures this catches have actually happened. Commits have gone out
# with a bare scope prefix (`rules:`, `bench:`) and no versions at all. And
# the `spicy` edition shipped with the api version left alone, which meant
# no client saw skew, which meant open tabs never reloaded and could not
# offer the edition that had just shipped — a stale version number is not a
# cosmetic problem, it is the signal the web client reloads on.
#
# Checking the numbers against the tree is the part a human reviewer can't
# reliably do: `app 0.4.13` in a subject looks equally right whether or not
# Cargo.toml says 0.4.13.
#
# Usage:
#   ./scripts/check-commit-stamp.sh              # HEAD only
#   ./scripts/check-commit-stamp.sh <range>      # e.g. origin/main..HEAD
#
# Merge commits are skipped: they carry no change of their own, and their
# subject is generated.

RANGE="${1:-HEAD~0..HEAD}"
if [[ "$RANGE" == "HEAD~0..HEAD" ]]; then
  # `--no-merges` on this path too, or the promise above holds only for the
  # range form. CI falls back to the no-argument call when `github.event.before`
  # is all zeros — which is what a newly pushed branch looks like — so a branch
  # whose tip is a merge would fail for a reason that is not real.
  if git rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then
    COMMITS=""
  else
    COMMITS="$(git rev-parse HEAD)"
  fi
else
  # --no-merges: a merge's subject is generated and describes no change.
  COMMITS="$(git rev-list --no-merges "$RANGE" 2>/dev/null || true)"
fi

if [[ -z "$COMMITS" ]]; then
  echo "no commits to check in '$RANGE'"
  exit 0
fi

# `app 1.2.3 api 4.5: something` — the subject after the colon must be
# non-empty, so the stamp can't be the whole message.
STAMP='^app ([0-9]+\.[0-9]+\.[0-9]+) api ([0-9]+\.[0-9]+): .+'

failed=0
checked=0

for sha in $COMMITS; do
  short="$(git rev-parse --short "$sha")"
  subject="$(git log -1 --format=%s "$sha")"
  checked=$((checked + 1))

  if [[ ! "$subject" =~ $STAMP ]]; then
    echo "FAIL $short: subject doesn't start with the version stamp"
    echo "     got:    $subject"
    echo "     wanted: app <X.Y.Z> api <M.N>: <subject>"
    failed=$((failed + 1))
    continue
  fi

  claimed_app="${BASH_REMATCH[1]}"
  claimed_api="${BASH_REMATCH[2]}"

  # Read the versions as they were *at that commit*, not as they are now —
  # a stamp is a claim about its own tree.
  actual_app="$(git show "$sha:Cargo.toml" 2>/dev/null \
    | grep -m1 '^version' | cut -d'"' -f2 || true)"
  # `|| true` because a commit predating the api crate has none to read. It
  # does mean an unreadable version skips the check below rather than failing
  # it — which is what happened when the constant wrapped onto four lines and
  # this quietly stopped verifying anything. One parser now, with its own
  # tests, so the shape cannot drift away from the reader again.
  actual_api="$(git show "$sha:crates/api/src/lib.rs" 2>/dev/null \
    | "$(dirname "$0")/read-api-version.sh" 2>/dev/null || true)"

  if [[ -n "$actual_app" && "$claimed_app" != "$actual_app" ]]; then
    echo "FAIL $short: subject says app $claimed_app, Cargo.toml says $actual_app"
    echo "     $subject"
    failed=$((failed + 1))
    continue
  fi

  if [[ -n "$actual_api" && "$claimed_api" != "$actual_api" ]]; then
    echo "FAIL $short: subject says api $claimed_api, API_VERSION is $actual_api"
    echo "     $subject"
    echo "     If this change adds something a client can observe — including a"
    echo "     new accepted *value*, such as an edition — the api minor should"
    echo "     move, and the subject should say so."
    failed=$((failed + 1))
    continue
  fi

  # The check above cannot catch the mistake that actually happened: a
  # commit whose api version *should* have moved and didn't is entirely
  # self-consistent, so nothing in the stamp contradicts the tree. The best
  # available signal is that the change touched something a client can
  # observe while API_VERSION stood still. Warn rather than fail — a
  # comment-only edit to the api crate would trip it, and a lint that cries
  # wolf gets ignored, which is worse than one that occasionally misses.
  touched_wire=0
  git diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null \
    | grep -qE '^crates/api/src/|^crates/rules-shared/src/model\.rs$' && touched_wire=1
  if (( touched_wire == 1 )); then
    parent_api="$(git show "$sha~1:crates/api/src/lib.rs" 2>/dev/null \
      | "$(dirname "$0")/read-api-version.sh" 2>/dev/null || true)"
    if [[ -n "$parent_api" && "$parent_api" == "$actual_api" ]]; then
      echo "warn $short: touched the wire surface but left api at $actual_api"
      echo "     $subject"
      echo "     If a client can now observe something it couldn't — a new route,"
      echo "     a changed DTO, or a new accepted value such as an edition — the"
      echo "     minor should move. If not, ignore this."
    fi
  fi
done

if (( failed > 0 )); then
  echo
  echo "$failed of $checked commit(s) failed. Fix with: git commit --amend  (or rebase for older ones)"
  exit 1
fi

echo "commit stamp OK ($checked commit(s))"
