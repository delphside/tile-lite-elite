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

_SHIPPING_CMD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/programme/board/board-shipping.py"

# **A profile that cannot be read is neither yes nor no.** What ships is the
# technical profile's (#485), and its loader exits 70 when the profile or a key
# is missing, a status no answer uses (`board-shipping.py` answers 0 or 1).
# Every caller branches on 0 against anything else, so left alone 70 would read
# as "does not reach the image" and a gate would fail open. So on 70 these stop
# the script, with the loader's message: `exit` ends the caller when it runs the
# function in its own shell, as `if touches_image …` does. Inside a command
# substitution it ends only the substitution, which is why `deploy.sh` also asks
# for the profile once before it does anything (`require_shipping_profile`).
_PROFILE_ERROR=70

# _ask_shipping <args...> -> the answer's status; stops the script on a profile error.
_ask_shipping() {
  local err status=0
  err="$(python3 "$_SHIPPING_CMD" -C "${REPO_DIR:-.}" "$@" </dev/null 2>&1 >/dev/null)" || status=$?
  if (( status == _PROFILE_ERROR )); then
    printf 'shipping-paths: what ships cannot be decided, the profile is unreadable:\n%s\n' "$err" >&2
    exit "$_PROFILE_ERROR"
  fi
  return "$status"
}

# require_shipping_profile -> stops the script unless the profile can be read.
require_shipping_profile() {
  _ask_shipping check || true
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
