#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/shipping-paths.sh's touches_image_range — the pull-request
# half of #348: e2e should run on a pull request when, and only when, its
# diff as a whole reaches the image, using the one definition of "reaches the
# image" the pre-commit hook and deploy.sh already share (NON_SHIPPING).
#
# touches_image (the single-commit form) already has coverage via
# deploy-artifact.test.sh; this covers the range form CI actually needs,
# because a pull request is a diff between two refs, not one commit.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

setup() {
  REPO_DIR="$(mktemp -d)"
  git -C "$REPO_DIR" init -q .
  git -C "$REPO_DIR" config user.email t@t
  git -C "$REPO_DIR" config user.name t
  mkdir -p "$REPO_DIR/docs" "$REPO_DIR/crates/ui/src" "$REPO_DIR/scripts"

  echo one > "$REPO_DIR/docs/a.md"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m base
  BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
}

teardown() { rm -rf "$REPO_DIR"; }

source "$HERE/scripts/shipping-paths.sh"

# A pull request whose every commit touches only docs/ — the #345 case #348
# was raised from.
setup
echo two > "$REPO_DIR/docs/b.md"; git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "docs only, commit 1"
echo three > "$REPO_DIR/docs/c.md"; git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "docs only, commit 2"
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

status=0
touches_image_range "$BASE_SHA" "$HEAD_SHA" || status=$?
check "a pull request touching only docs across several commits does not reach the image" 1 "$status"
teardown

# A pull request where only one of several commits touches the image — the
# per-commit form would have to be run once per commit and OR'd; the range
# form answers it in one diff.
setup
echo two > "$REPO_DIR/docs/b.md"; git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "docs only"
echo three > "$REPO_DIR/crates/ui/src/x.rs"; git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "the image changes"
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

status=0
touches_image_range "$BASE_SHA" "$HEAD_SHA" || status=$?
check "a pull request reaches the image if any of its commits does" 0 "$status"
teardown

# A pull request that changes scripts/ only — non-shipping, same as docs.
setup
echo four > "$REPO_DIR/scripts/build.sh"; git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "tooling only"
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

status=0
touches_image_range "$BASE_SHA" "$HEAD_SHA" || status=$?
check "a pull request touching only scripts/ does not reach the image" 1 "$status"
teardown

if (( failures )); then
  echo "  $failures check(s) failed"
  exit 1
fi
echo "  all checks passed"
