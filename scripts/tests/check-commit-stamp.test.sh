#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/check-commit-stamp.sh, under the same `set -euo pipefail` its
# callers run with.
#
# This gate has failed open once already: an unguarded parse returned nothing,
# `|| true` swallowed it, and the check passed every commit for weeks while
# appearing to work. A gate that has stopped checking looks exactly like a gate
# everything passed, which is why it needs a test that watches it say **no**.
#
# So the cases below are mostly refusals. A test that only proves the happy
# path would have been green throughout that entire period.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/check-commit-stamp.sh"
failures=0

# A scratch repo carrying the two files the stamp is checked against.
new_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q .
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name Test
  mkdir -p "$dir/crates/api/src"
  printf '%s' "$dir"
}

# Commits `$3` as the subject, with the tree claiming app `$1` and api `$2`.
commit_at() {
  local dir="$1" app="$2" api="$3" subject="$4"
  printf '[workspace.package]\nversion = "%s"\n' "$app" > "$dir/Cargo.toml"
  printf 'pub const API_VERSION: ApiVersion = ApiVersion { major: %s, minor: %s };\n' \
    "${api%%.*}" "${api##*.}" > "$dir/crates/api/src/lib.rs"
  # A nonce, so two commits claiming the same versions still differ. Without it
  # git refuses the second as empty and the test aborts rather than failing.
  date +%s%N >> "$dir/nonce"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$subject"
}

check() {
  local name="$1" want="$2" dir="$3" range="${4:-}"
  local got=0
  ( cd "$dir" && "$CHECK" $range ) > /dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want, got $got"
    failures=$((failures + 1))
  fi
  rm -rf "$dir"
}

# --- it says yes when it should -------------------------------------------

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: a subject"
check "a stamp true of its own tree passes" 0 "$d"

# --- and no when it should, which is the half that matters ------------------

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "no stamp at all"
check "a missing stamp is refused" 1 "$d"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "rules: a bare scope prefix"
check "a bare scope prefix is refused" 1 "$d"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.24 api 2.10: claims the wrong app version"
check "an app version the tree disagrees with is refused" 1 "$d"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.9: claims the wrong api version"
check "an api version the tree disagrees with is refused" 1 "$d"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10:"
check "a stamp with no subject after it is refused" 1 "$d"

# The failure that started all this: `API_VERSION` wrapped onto four lines when
# the minor reached two digits, and the old parser returned nothing. Nothing is
# indistinguishable from "no api crate here", so the check skipped itself.
# read-api-version.sh handles both shapes now, and this pins that it still does
# through *this* caller rather than only in its own tests.
d="$(new_repo)"
printf '[workspace.package]\nversion = "0.4.25"\n' > "$d/Cargo.toml"
printf 'pub const API_VERSION: ApiVersion = ApiVersion {\n    major: 2,\n    minor: 10,\n};\n' \
  > "$d/crates/api/src/lib.rs"
git -C "$d" add -A
git -C "$d" commit -q -m "app 0.4.25 api 2.9: wrong api, with the constant wrapped"
check "a wrapped API_VERSION is still read, not skipped" 1 "$d"

# --- ranges and merges ------------------------------------------------------

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: first"
BASE="$(git -C "$d" rev-parse HEAD)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: second"
commit_at "$d" "0.4.25" "2.10" "bad subject on the third"
check "a range checks every commit in it, not just the tip" 1 "$d" "$BASE..HEAD"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: on main"
git -C "$d" checkout -q -b side
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: on the side"
git -C "$d" checkout -q -
BASE="$(git -C "$d" rev-parse HEAD)"
git -C "$d" merge -q --no-ff side -m "Merge: a generated subject with no stamp" 2>/dev/null
check "a merge commit is skipped, its subject describing no change" 0 "$d" "$BASE..HEAD"

d="$(new_repo)"
commit_at "$d" "0.4.25" "2.10" "app 0.4.25 api 2.10: only commit"
check "an empty range passes rather than erroring" 0 "$d" "HEAD..HEAD"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All check-commit-stamp tests passed."
