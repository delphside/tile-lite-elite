#!/usr/bin/env bash
set -euo pipefail

# sync-pr-state.sh — put every pull request on the board, and set `PR State`
# from what GitHub already knows.
#
# **The field is derived, never typed.** `actions.py` reads whose turn a pull
# request is on from `isDraft`, `reviewDecision` and whether a review is
# requested, and its own comment records why: the `approved` and
# `awaiting-review` labels were deleted in #219 because they were a second
# store for what GitHub already knew. A board column set by hand is the same
# mistake with a different surface, and it went wrong within a day — #338 and
# #341 sat in **Approved** after both had merged.
#
# So this is the same shape as `docs/1.5` and the delivery log: generated from
# the source, not maintained beside it. If the field disagrees with
# `reviewDecision`, the field is wrong.
#
# **It also adds what is missing.** GitHub's auto-add workflow is configured in
# the project's settings and has no API — `updateProjectV2Workflow` does not
# exist — so nothing here can widen it to pull requests. #364 and #365 were
# raised and never appeared. Adding them is idempotent: an item that exists
# comes back with its own id rather than a duplicate.
#
# Usage:
#   ./scripts/sync-pr-state.sh            # add what is missing, set what is wrong
#   ./scripts/sync-pr-state.sh --check    # report the drift and change nothing
#
# Exits 0 when the board agrees with GitHub, 1 from `--check` when it does not.
# A check reports and a person decides; the plain form is the person deciding.

PROJECT_ID="${PROJECT_ID:-PVT_kwDOEyOvmc4BhpOl}"
FIELD_ID="${PR_STATE_FIELD_ID:-PVTSSF_lADOEyOvmc4BhpOlzhhydyI}"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# The option ids, which are opaque and short-lived enough to be worth reading
# rather than hard-coding. A renamed option would otherwise write nothing and
# say it worked.
OPTIONS="$(gh api graphql -f query="{node(id:\"$PROJECT_ID\"){... on ProjectV2{
  fields(first:50){nodes{... on ProjectV2SingleSelectField{name options{id name}}}}}}}" \
  --jq '.data.node.fields.nodes[] | select(.name=="PR State") | .options[] | "\(.name)\t\(.id)"' 2>/dev/null || true)"
if [[ -z "$OPTIONS" ]]; then
  echo "sync-pr-state: no 'PR State' field on the project — nothing to sync" >&2
  exit 2
fi
option_id() { awk -F'\t' -v n="$1" '$1==n{print $2}' <<< "$OPTIONS"; }

# **The same ladder `actions.py` uses**, plus the two terminal states it has no
# reason to name. Kept in one place so the board and the action list cannot
# disagree about whose turn it is.
derive() {
  local state="$1" draft="$2" review="$3" reviewers="$4"
  case "$state" in
    MERGED) echo "Merged"; return ;;
    CLOSED) echo "Closed"; return ;;
  esac
  [[ "$draft" == "true" ]] && { echo "Drafting"; return; }
  [[ "$review" == "APPROVED" ]] && { echo "Approved"; return; }
  [[ "$review" == "CHANGES_REQUESTED" ]] && { echo "Changes requested"; return; }
  [[ "$reviewers" != "0" ]] && { echo "Awaiting review"; return; }
  echo "Drafting"
}

# **Every field is emitted non-empty**, because tab is an IFS whitespace
# character: `read` collapses a run of them, so one empty field shifts every
# later one left. `reviewDecision` comes back as an empty *string* rather than
# null for a pull request nobody has reviewed, so `// "none"` never fires — and
# the node id then lands in the wrong variable and the add fails with
# `global id of ''`. `check-transitions.sh` carries the same note; this walked
# into it anyway on 2026-09-10.
PRS="$(gh pr list --state all --limit 500 \
  --json number,state,isDraft,reviewDecision,reviewRequests,id \
  --jq '.[] | [.number, .state, (.isDraft|tostring),
               (if (.reviewDecision // "") == "" then "none" else .reviewDecision end),
               ((.reviewRequests|length)|tostring), .id] | @tsv')"

# Every page of the board, because a partial read looks exactly like an absent
# item — which is how "no pull requests are on the board" was reported on
# 2026-09-09 when three were.
ITEMS=""; cursor="null"
while :; do
  page="$(gh api graphql -f query="{node(id:\"$PROJECT_ID\"){... on ProjectV2{
    items(first:100,after:$cursor){pageInfo{hasNextPage endCursor}
      nodes{id content{... on PullRequest{number}}
        fieldValues(first:25){nodes{... on ProjectV2ItemFieldSingleSelectValue{
          name field{... on ProjectV2FieldCommon{name}}}}}}}}}}")"
  ITEMS+="$(printf '%s' "$page" | jq -r '.data.node.items.nodes[]
    | select(.content.number != null)
    | "\(.content.number)\t\(.id)\t" + ([.fieldValues.nodes[]
        | select(.field.name=="PR State") | .name][0] // "")')"$'\n'
  [[ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" == "true" ]] || break
  cursor="\"$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')\""
done

added=0; changed=0; drift=0
while IFS=$'\t' read -r num state draft review reviewers node; do
  [[ -n "$num" ]] || continue
  want="$(derive "$state" "$draft" "$review" "$reviewers")"
  line="$(awk -F'\t' -v k="$num" '$1==k{print; exit}' <<< "$ITEMS" || true)"
  item="$(cut -f2 <<< "$line")"; have="$(cut -f3 <<< "$line")"

  if [[ -z "$item" ]]; then
    drift=$((drift+1))
    if (( CHECK )); then echo "  #$num is not on the board — should be '$want'"; continue; fi
    item="$(gh api graphql -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' \
      -f p="$PROJECT_ID" -f c="$node" --jq '.data.addProjectV2ItemById.item.id' 2>/dev/null || true)"
    # A failed mutation prints its error and yields nothing useful; counting it
    # as added is how "2 added" was reported for two adds that did not happen.
    [[ "$item" == PVTI_* ]] || { echo "  #$num could not be added" >&2; continue; }
    added=$((added+1)); have=""
  fi

  [[ "$have" == "$want" ]] && continue
  drift=$((drift+1))
  if (( CHECK )); then
    echo "  #$num says '${have:-unset}', GitHub says '$want'"
    continue
  fi
  gh api graphql -f query='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' \
    -f p="$PROJECT_ID" -f i="$item" -f f="$FIELD_ID" -f o="$(option_id "$want")" > /dev/null \
    && { echo "  #$num ${have:-unset} -> $want"; changed=$((changed+1)); }
done <<< "$PRS"

if (( CHECK )); then
  (( drift == 0 )) && { echo "sync-pr-state: the board agrees with GitHub"; exit 0; }
  echo "sync-pr-state: $drift pull request(s) drifted"; exit 1
fi
echo "sync-pr-state: $added added, $changed corrected"
