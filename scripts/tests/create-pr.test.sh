#!/usr/bin/env bash
set -euo pipefail

# create-pr.test.sh — #410's lesson: creation had no choke point, so the
# board sat unset until something else happened to run sync-pr-state.sh.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/create-pr.sh"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# `gh` stubbed for the one call this script makes: `pr create`. Records the
# whole argument list, so the reviewer default and passthrough are both
# checkable.
cat > "$DIR/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr create" ]]; then
  printf '%s\n' "$*" > "$STUB_DIR/CREATED"
  [[ -n "${GH_CREATE_FAIL:-}" ]] && exit 1
  exit 0
fi
echo "unexpected gh: $*" >&2; exit 9
STUB
chmod +x "$DIR/gh"

cat > "$DIR/sync-pr-state.sh" <<'STUB'
#!/usr/bin/env bash
echo "ran" > "$STUB_DIR/SYNCED"
[[ -n "${SYNC_FAIL:-}" ]] && exit 1
exit 0
STUB
chmod +x "$DIR/sync-pr-state.sh"

export PATH="$DIR:$PATH"
export STUB_DIR="$DIR"
export SYNC_PR_STATE="$DIR/sync-pr-state.sh"

reset() { rm -f "$DIR/CREATED" "$DIR/SYNCED"; unset GH_CREATE_FAIL SYNC_FAIL || true; }
check() { local d="$1" e="$2" g="$3"
  if [ "$g" = "$e" ]; then echo "  ok       $d"
  else echo "  FAILED   $d (expected $e, got $g)"; failures=$((failures+1)); fi }
created() { [ -f "$DIR/CREATED" ] && cat "$DIR/CREATED" || echo ""; }
synced() { [ -f "$DIR/SYNCED" ] && echo yes || echo no; }

failures=0
echo "create-pr.sh"

reset
"$SCRIPT" --base main --head x --title t --body-file /dev/null > /dev/null 2>&1
check "reviewer defaults to SteveStyle" "1" \
  "$(grep -c -- '--reviewer SteveStyle' <<< "$(created)")"
check "and corrects the board after" "yes" "$(synced)"

reset
"$SCRIPT" --base main --head x --title t --body-file /dev/null --reviewer other > /dev/null 2>&1
check "an explicit --reviewer overrides the default" "1" \
  "$(grep -c -- '--reviewer other' <<< "$(created)")"
check "and the default is not also passed" "0" \
  "$(grep -c -- '--reviewer SteveStyle' <<< "$(created)")"

reset
rc=0; "$SCRIPT" --head x --title t --body-file /dev/null > /dev/null 2>&1 || rc=$?
check "a missing --base is a usage error" "2" "$rc"
check "and nothing was created" "" "$(created)"

reset
rc=0; GH_CREATE_FAIL=1 "$SCRIPT" --base main --head x --title t --body-file /dev/null > /dev/null 2>&1 || rc=$?
check "a failed gh pr create is not swallowed" "1" "$rc"
check "and the board is not touched for a PR that does not exist" "no" "$(synced)"

reset
out="$("$SCRIPT" --base main --head x --title t --body-file /dev/null 2>&1)"
SYNC_FAIL=1 out2="$(SYNC_FAIL=1 "$SCRIPT" --base main --head x --title t --body-file /dev/null 2>&1)"
check "a failed sync still reports the pull request created" "0" \
  "$(grep -c 'FAILED\|error' <<< "$out2" || true)"
check "and says where to run it by hand" "1" \
  "$(grep -c 'run scripts/sync-pr-state.sh' <<< "$out2")"

echo
if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
