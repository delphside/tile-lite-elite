#!/usr/bin/env bash
# shipping-paths.sh — which repository paths reach the image.
#
# Sourced by `.githooks/pre-commit` (the image rule, which refuses such a change
# on `main`) and by `deploy.sh` (the build manifest, which marks the commits
# that reach users). One definition in one file, for the reason
# `issue-mentions.sh` gives about itself: two copies is how the same defect
# comes to exist in two places, and this one decides both whether a commit is
# refused and whether a release is described correctly.
#
# **The rule is the model's**, `scripts/programme/board/shipping.py`, since 2026-09-26
# (#421): it was `NON_SHIPPING` here, and the reasoning moved with it. This file
# keeps the two functions its callers source, and each asks
# `scripts/programme/board/board-shipping.py` rather than holding a pattern of its own.
#
# `-C "${REPO_DIR:-.}"` because deploy.sh addresses its repository explicitly
# everywhere else and this must agree with it; bare `git` reads the current
# directory, which under test inspected the real repository instead of the
# fixture. `</dev/null` because these run inside `while read` loops in
# deploy.sh, where a command inheriting the loop's stdin consumes lines it has
# not read yet.

_SHIPPING_CMD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../programme/board/board-shipping.py"

# touches_image <commit-ish> -> 0 if any path it changed reaches the image.
touches_image() {
  python3 "$_SHIPPING_CMD" -C "${REPO_DIR:-.}" commit "$1" </dev/null 2>/dev/null
}

# touches_image_range <base> <head> -> 0 if the diff between the two reaches
# the image. For a proposed change as a whole — a pull request — rather than
# one commit: CI asks this once per pull request, not once per commit in it
# (#348).
touches_image_range() {
  python3 "$_SHIPPING_CMD" -C "${REPO_DIR:-.}" range "$1" "$2" </dev/null 2>/dev/null
}

# ships <commit-ish> -> 0 if it carries anything to release: it reaches the
# image and is more than the version moving. The version bump after a release
# touches Cargo.toml and ships nothing, so a question about unreleased work asks
# this rather than touches_image.
ships() {
  python3 "$_SHIPPING_CMD" -C "${REPO_DIR:-.}" ships "$1" </dev/null 2>/dev/null
}
