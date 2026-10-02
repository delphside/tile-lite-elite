#!/usr/bin/env bash
set -euo pipefail

# read-api-version.sh — print the api version as `M.N`, read from a Rust
# source file on stdin.
#
# One parser, because there were two and they drifted the moment the constant
# changed shape. `API_VERSION` is written by rustfmt, which wraps the
# declaration once the numbers grow — which it did the first time a minor
# reached two digits:
#
#     pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 9 };
#
#     pub const API_VERSION: ApiVersion = ApiVersion {
#         major: 2,
#         minor: 10,
#     };
#
# Both callers assumed the first. In `deploy.sh` the failure took the release
# down between `git add` and `git commit`; in `check-commit-stamp.sh` it was
# guarded with `|| true`, so the empty result silently skipped the check and
# CI went on passing commits it was no longer verifying. Loud and quiet
# failures of the same bug, which is why the parsing lives in one place now.
#
# Exits non-zero if it cannot find a version, so a caller cannot mistake
# "could not read" for "no change".
#
#   git show HEAD:crates/api/src/lib.rs | ./scripts/read-api-version.sh

version="$(tr '\n' ' ' \
  | sed -nE 's/.*API_VERSION[^=]*=[^{]*\{[^}]*major: *([0-9]+)[^}]*minor: *([0-9]+).*/\1.\2/p' \
  | head -1)"

if [[ -z "$version" ]]; then
  echo "read-api-version.sh: no API_VERSION found on stdin" >&2
  exit 1
fi

printf '%s\n' "$version"
