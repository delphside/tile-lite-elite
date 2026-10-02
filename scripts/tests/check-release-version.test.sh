#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/check-release-version.sh under the same `set -euo pipefail` its
# callers run with. A harness that relaxes it once let a silent-abort bug into a
# production deploy (docs/3.3, "Rolling back"), and this script runs *during* a
# release, so the same trap is live here.
#
# The cases that matter are the ones where it must NOT fail: a release should
# never be blocked because a tag is missing or GitHub is unreachable.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$HERE/check-release-version.sh"
failures=0

# Runs the check in a scratch git repo with no tags and no `gh` reachable, so
# the only inputs are the arguments.
#
# The isolation builds a PATH containing symlinks to exactly the tools the
# script uses, and nothing else. An earlier version set `PATH=/usr/bin:/bin`
# and passed here while failing in CI, because `gh` lives in `~/.local/bin` on
# this machine and in `/usr/bin` on a GitHub runner — a test that depended on
# where a binary happened to be installed. Naming the tools is the only way to
# be sure of what is absent.
run_isolated() {
  local version="$1" previous="${2:-}"
  local dir bin
  dir="$(mktemp -d)"
  bin="$dir/bin"
  mkdir -p "$bin"
  # Everything the script reaches for, including what its own shebang and
  # heredoc need — `env` and `bash` to start at all, `cat` to print the
  # explanation. A missing one shows up as exit 127, not as a wrong answer.
  for tool in env bash cat git sed sort tail; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  (
    cd "$dir"
    PATH="$bin" git init -q .
    PATH="$bin" "$CHECK" "$version" "$previous" 2>&1
  )
  local status=$?
  rm -rf "$dir"
  return $status
}

check_exit() {
  local name="$1" want="$2"
  shift 2
  local got=0
  "$@" > /dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want, got $got"
    failures=$((failures + 1))
  fi
}

check_says() {
  local name="$1" want="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if [[ "$out" == *"$want"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: output did not mention '$want'"
    echo "     got: $out"
    failures=$((failures + 1))
  fi
}

# --- refuses to judge without enough information ---------------------------
# Each of these is a release that must go ahead.

check_exit "no previous release passes" 0 run_isolated "0.4.26"
check_says "and says why" "no previous release" run_isolated "0.4.26"

check_exit "unparseable previous release passes" 0 run_isolated "0.4.26" "not-a-version"
check_says "and says why" "not an X.Y.Z version" run_isolated "0.4.26" "not-a-version"

check_exit "no gh available passes" 0 run_isolated "0.4.26" "0.4.25"
check_says "and says why" "gh not available" run_isolated "0.4.26" "0.4.25"

# --- a minor or major release is never wrong in this way -------------------

check_exit "minor release passes" 0 run_isolated "0.5.0" "0.4.25"
check_says "minor release says so" "minor or major release" run_isolated "0.5.0" "0.4.25"

check_exit "major release passes" 0 run_isolated "1.0.0" "0.4.25"

# A minor release is allowed to contain fixes, so it short-circuits before it
# would ever look at labels — which is why it passes even with no `gh`.
check_says "minor release does not need gh" "minor or major release" \
  run_isolated "0.5.0" "0.4.25"

# --- bad arguments are the caller's fault, not a skip -----------------------

check_exit "no version at all is a usage error" 2 "$CHECK"
check_exit "a non-version is a usage error" 2 "$CHECK" "banana"
check_exit "a two-part version is a usage error" 2 "$CHECK" "0.4"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All check-release-version tests passed."
