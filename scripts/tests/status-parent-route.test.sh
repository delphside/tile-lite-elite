#!/usr/bin/env bash
set -euo pipefail

# status-parent-route.test.sh — a parent owes no route, #297.
#
# `status.sh` asks every typed issue for a `Route` and reports the ones without
# as *"route not set — cannot say, and that is the thing to fix"*. That names
# the wrong thing to fix for an issue that owes no route, and it has now been
# wrong twice:
#
#   2026-09-09  requirements — #339, #340, #346 flagged while being correct
#   2026-09-17  parent projects — #297 flagged, and #214 and #344 given a
#               route to silence it, which the deploy then ignores
#
# The same defect on a different kind of issue, so the exemption is what needs
# holding rather than the reporting. The distinction is narrow and is the part
# that will break: **a parent is a project with sub-issues that are themselves
# projects**, not a project with any sub-issues. A project carries folded
# requirements as sub-issues routinely and is still one delivery owing one
# route — #214 has two work packages and two folded requirements.
#
# `type_of_issue` is extracted from `status.sh` rather than copied, so the test
# reads the shipped filter and cannot drift from it. `gh` is stubbed; the
# canned JSON is the only input.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"
PATH="$BIN:$PATH"

REPO_OWNER="delphside"; REPO_NAME="tile-lite-elite"
export REPO_OWNER REPO_NAME

# The real function, read out of the script under test.
eval "$(sed -n '/^type_of_issue() {$/,/^}$/p' "$HERE/status.sh")"
if ! declare -F type_of_issue > /dev/null; then
  echo "FAIL could not extract type_of_issue from status.sh" >&2
  exit 1
fi

# One canned issue. $1 title, $2 route ("" for unset), $3 issue type,
# $4.. the issue types of its sub-issues.
canned() {
  local title="$1" route="$2" kind="$3"; shift 3
  local subs="" sep=""
  for t in "$@"; do subs="$subs$sep{\"issueType\":{\"name\":\"$t\"}}"; sep=","; done
  local fields="{\"value\":\"tooling\",\"field\":{\"name\":\"Type of change\"}}"
  [[ -n "$route" ]] && fields="$fields,{\"value\":\"$route\",\"field\":{\"name\":\"Route\"}}"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
# Only the graphql call matters; --jq is applied by the caller's gh, so do it here.
args=("\$@"); jqf=""
for ((i=0; i<\${#args[@]}; i++)); do
  [[ "\${args[i]}" == "--jq" ]] && jqf="\${args[i+1]}"
done
printf '%s' '{"data":{"repository":{"issue":{"title":"$title","issueType":{"name":"$kind"},"subIssues":{"nodes":[$subs]},"issueFieldValues":{"nodes":[$fields]}}}}}' \
  | jq -r "\$jqf"
EOF
  chmod +x "$BIN/gh"
}

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want %-10s got %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

parent_flag() { IFS=$'\t' read -r _ _ _ _ p <<< "$(type_of_issue 1)"; printf '%s' "$p"; }
route_of()    { IFS=$'\t' read -r _ _ r _ _ <<< "$(type_of_issue 1)"; printf '%s' "$r"; }

echo "a parent is a project with project sub-issues"

# #214 as it actually is: two work packages and two folded requirements.
canned "MAIN PROJECT: one deployment path" "" "Project" Project Project Requirement Requirement
check "two work packages and two folded requirements -> parent" "parent" "$(parent_flag)"

# A project whose only sub-issues are folded requirements is NOT a parent: it
# is one delivery and owes a route. This is the case the narrow test exists for.
canned "a project that folded two requirements" "Repository Change" "Project" Requirement Requirement
check "folded requirements only -> not a parent" "-" "$(parent_flag)"

# A standalone project with nothing under it.
canned "a standalone project" "Production Release" "Project"
check "no sub-issues -> not a parent" "-" "$(parent_flag)"

# A work package is a project too, and owes its own route.
canned "WP A Del 1 of 2" "Production Release" "Project"
check "work package -> not a parent" "-" "$(parent_flag)"

# A decision carrying sub-issues must not be read as a parent project.
canned "[Decision]: D54" "" "Decision" Project
check "a Decision is not a parent project" "parent" "$(parent_flag)"

echo
echo "the route still reads correctly alongside it"
canned "a standalone project" "Production Release" "Project"
check "route survives the extra column" "Production Release" "$(route_of)"
canned "MAIN PROJECT" "" "Project" Project
check "an unset route reads as unset" "-" "$(route_of)"

echo
if (( failures )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all parent-route cases hold"
