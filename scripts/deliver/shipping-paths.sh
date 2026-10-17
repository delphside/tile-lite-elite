#!/usr/bin/env bash
# shipping-paths.sh — which repository paths reach the image.
#
# Sourced by `deploy.sh`, `verify.sh` and CI (the pre-commit hook, in the programme,
# asks `board-shipping.py` directly, since it is not this repository's script). It decides
# both what refuses an image change on `main` and `deploy.sh` (the build manifest, which marks the commits
# that reach users). One definition in one file, for the reason
# `issue-mentions.sh` gives about itself: two copies is how the same defect
# comes to exist in two places, and this one decides both whether a commit is
# refused and whether a release is described correctly.
#
# **The rule is the model's**, `programme/scripts/board/shipping.py`, since 2026-09-26
# (#421): it was `NON_SHIPPING` here, and the reasoning moved with it. This file
# keeps the two functions its callers source, and each asks
# `programme/scripts/board/board-shipping.py` rather than holding a pattern of its own.
#
# `-C "${REPO_DIR:-.}"` because deploy.sh addresses its repository explicitly
# everywhere else and this must agree with it; bare `git` reads the current
# directory, which under test inspected the real repository instead of the
# fixture. `</dev/null` because these run inside `while read` loops in
# deploy.sh, where a command inheriting the loop's stdin consumes lines it has
# not read yet.

_SHIPPING_CMD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/programme/scripts/board/board-shipping.py"

# **Only 0 and 1 are answers.** `board-shipping.py` says yes with 0 and no with 1,
# and every caller branches on 0 against anything else, so any other status read
# as "no" and a gate failed open. 70 is the loader refusing: what ships is the
# technical profile's (#485), and it exits 70 when the profile or a key is
# missing. 2 is Python not finding the script, which is the `programme/`
# submodule not being checked out (the stamp job in CI did that). 126, 127 and
# a signal are the same kind of thing. So on any other status these stop the
# script, with the message the command gave: `exit` ends the caller when it runs
# the function in its own shell, as `if touches_image …` does. Inside a command
# substitution it ends only the substitution, which is why `deploy.sh` also asks
# for the profile once before it does anything (`require_shipping_profile`).
_PROFILE_ERROR=70

# _ask_shipping <args...> -> the answer's status (0 or 1); stops the script on anything else.
_ask_shipping() {
  local err status=0
  if [[ ! -f "$_SHIPPING_CMD" ]]; then
    printf 'shipping-paths: what ships cannot be decided, %s is missing.\nThe programme submodule is not initialised: run git submodule update --init\n' \
      "$_SHIPPING_CMD" >&2
    exit "$_PROFILE_ERROR"
  fi
  err="$(python3 "$_SHIPPING_CMD" -C "${REPO_DIR:-.}" "$@" </dev/null 2>&1 >/dev/null)" || status=$?
  if (( status > 1 )); then
    printf 'shipping-paths: what ships cannot be decided (status %s):\n%s\n' "$status" "$err" >&2
    exit "$_PROFILE_ERROR"
  fi
  return "$status"
}

# require_shipping_profile -> stops the script unless the profile can be read.
require_shipping_profile() {
  # `check` has no "no": a 1 means the command failed before it could answer.
  _ask_shipping check || {
    printf 'shipping-paths: the shipping rule could not be checked (status 1).\n' >&2
    exit "$_PROFILE_ERROR"
  }
}

# touches_image <commit-ish> -> 0 if any path it changed reaches the image.
touches_image() {
  _ask_shipping commit "$1"
}

# touches_image_range <base> <head> -> 0 if the diff between the two reaches
# the image. For a proposed change as a whole — a pull request — rather than
# one commit: CI asks this once per pull request, not once per commit in it
# (#348).
touches_image_range() {
  _ask_shipping range "$1" "$2"
}

# ships <commit-ish> -> 0 if it carries anything to release: it reaches the
# image and is more than the version moving. The version bump after a release
# touches the manifest and ships nothing, so a question about unreleased work asks
# this rather than touches_image.
ships() {
  _ask_shipping ships "$1"
}
