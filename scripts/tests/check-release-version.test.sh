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

# The same, but with a stubbed `gh` so the API path is actually driven.
#
# **Every case above runs with no `gh` at all**, which means the query that
# decides whether a milestone carries functional change had never been
# exercised by a test — it was rewritten from REST to GraphQL on 2026-08-26,
# when the type of change moved from a label to an issue field, and the suite
# stayed green throughout because it could not see the path.
#
#   $1 version   $2 previous   $3 what `gh api graphql` should print
run_with_gh() {
  local version="$1" previous="$2" answer="$3"
  local dir bin
  dir="$(mktemp -d)"; bin="$dir/bin"; mkdir -p "$bin"
  for tool in env bash cat git sed sort tail jq; do
    ln -s "$(command -v "$tool")" "$bin/$tool" 2>/dev/null || true
  done
  printf '%s' "$answer" > "$dir/answer.json"
  # **The stub runs the real `--jq` filter.** Returning pre-filtered output
  # would exercise the script's branching and not its query — and the query is
  # what changed. A filter selecting nothing looks exactly like a milestone
  # with nothing functional in it, which is the failure this has to be able to
  # see. It could not: `any(. == "a", "b")` is jq's one-argument form with a
  # generator whose second value is a truthy string, so it matched everything.
  cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
filter=""; prev=""
for a in "$@"; do
  [[ "$prev" == "--jq" ]] && filter="$a"
  prev="$a"
done
case "$*" in
  *"repo view"*) printf '%s\n' "delphside/tile-lite-elite" ;;
  *graphql*)
    # Record the query, so a case can assert on what was *asked* and not only
    # on how the answer was parsed. Without this the stub proves the code can
    # read a response it is handed, which is how a query returning nothing
    # passed every case here for a fortnight.
    [[ -n "${QUERY_LOG:-}" ]] && printf '%s\n' "$*" >> "$QUERY_LOG"
    if [[ -n "$filter" ]]; then jq -r "$filter" < "$ANSWER_FILE"
    else cat "$ANSWER_FILE"; fi ;;
  *) : ;;
esac
STUB
  chmod +x "$bin/gh"
  (
    cd "$dir"
    PATH="$bin" git init -q .
    ANSWER_FILE="$dir/answer.json" PATH="$bin" "$CHECK" "$version" "$previous" 2>&1
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
# --- the API path, which nothing exercised until 2026-08-26 -------------------
#
# A patch release whose milestone carries a `functional` issue must be
# refused. This is the whole point of the check, and it was the one behaviour no
# test drove.

FUNCTIONAL_ANSWER='{"data":{"search":{"nodes":[
  {"number":123,"title":"a change a user could notice",
   "issueFieldValues":{"nodes":[
     {"value":"functional","field":{"name":"Type of change"}}]}}]}}}'

EMPTY_ANSWER='{"data":{"search":{"nodes":[]}}}'

TOOLING_ANSWER='{"data":{"search":{"nodes":[
  {"number":124,"title":"a script change",
   "issueFieldValues":{"nodes":[
     {"value":"tooling","field":{"name":"Type of change"}}]}}]}}}'

check_exit "a patch carrying functional change is refused" 1 \
  run_with_gh "0.4.26" "0.4.25" "$FUNCTIONAL_ANSWER"
check_says "and names the issue" "#123" \
  run_with_gh "0.4.26" "0.4.25" "$FUNCTIONAL_ANSWER"
check_exit "a patch carrying nothing functional passes" 0 \
  run_with_gh "0.4.26" "0.4.25" "$EMPTY_ANSWER"
check_exit "a patch carrying only tooling passes" 0 \
  run_with_gh "0.4.26" "0.4.25" "$TOOLING_ANSWER"
check_says "and says a patch is right" "a patch release is right" \
  run_with_gh "0.4.26" "0.4.25" "$TOOLING_ANSWER"

# --- the query itself, not only the parsing -----------------------------------
#
# **`is:issue` is load-bearing and its absence made this gate blind.** Measured
# against the live repository on 2026-09-09: `repo:… milestone:"0.7.3"` returns
# **0** issues where `repo:… is:issue milestone:"0.7.3"` returns **5**. So the
# check reported *nothing functional* for every release it ever ran on, because
# it always found nothing to judge.
#
# Every other case here stubs the answer, which is why none of them could catch
# it. This one asserts what was asked.
QUERY_LOG="$(mktemp)"; export QUERY_LOG
run_with_gh "0.4.26" "0.4.25" "$EMPTY_ANSWER" > /dev/null 2>&1 || true
check_says_literal() {
  local what="$1" want="$2"
  if grep -q -- "$want" "$QUERY_LOG"; then printf '  ok   %s\n' "$what"
  else printf '  FAIL %s\n       the query was: %s\n' "$what" "$(cat "$QUERY_LOG")"; failures=$((failures+1)); fi
}
check_says_literal "the search asks for is:issue" "is:issue"
check_says_literal "and still filters by the milestone" "milestone:"
rm -f "$QUERY_LOG"

if (( failures > 0 )); then
  echo "$failures test(s) failed" >&2
  exit 1
fi
echo "All check-release-version tests passed."
