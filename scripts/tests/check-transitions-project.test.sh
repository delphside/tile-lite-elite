#!/usr/bin/env bash
set -euo pipefail

# check-transitions-project.test.sh — the Project field rules, #346.
#
# A Requirement's fields were checked and a Project's never were, so a project
# could reach Development with no workstream, no effort and no milestone and
# nothing said so. These rules close that, and two of them are exemptions
# rather than demands — which is the half a test has to hold, because an
# exemption that stops working reports every main project as defective and the
# check is then ignored rather than fixed.
#
# `gh` is stubbed; the canned JSON is the only input. Run under the same
# `set -euo pipefail` the script runs under.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

mkbody() { printf '%s' "$1" | base64 -w0; }

SEVEN="$(mkbody '## Requirements

| | from | |

## Design

## Impacted artefacts

## Test approach

### Functional user tests — Preview

None.

### Technical tests — Rehearsal

None.

## Deliveries

## Post-deployment checks against requirements

| requirement | how | |
| --- | --- | --- |
| R1 | by reading | passed |
')"

BLANK_CHECKS="$(mkbody '## Requirements

## Design

## Impacted artefacts

## Test approach

### Functional user tests — Preview

None.

### Technical tests — Rehearsal

None.

## Deliveries

## Post-deployment checks against requirements

| requirement | how | |
| --- | --- | --- |
| R1 | by reading | |
| R2 | by looking | |
')"

# number, phase, body, extra field JSON, parent JSON, milestone JSON, subissue JSON
node() {
  printf '{"number":%s,"title":"t","body":null,"bodyB64":"","issueType":{"name":"Project"},%s%s"subIssues":{"nodes":[%s]},"issueFieldValues":{"nodes":[{"name":"%s","field":{"name":"Phase"}}%s]}}' \
    "$1" "$5" "$6" "$7" "$2" "$4"
}

run() {
  local desc="$1" want_text="$2" expect="$3" nodes="$4"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *states:CLOSED*) echo '{"data":{"repository":{"issues":{"nodes":[]}}}}'; exit 0 ;;
  esac
done
cat <<'JSON'
{"data":{"repository":{"issues":{"nodes":[$nodes]}}}}
JSON
EOF
  chmod +x "$BIN/gh"
  local out
  out="$(PATH="$BIN:$PATH" "$HERE/check-transitions.sh" 2>&1)" || true
  if [ "$expect" = "yes" ]; then
    if grep -qF "$want_text" <<< "$out"; then echo "  ok       $desc"
    else echo "  FAILED   $desc — expected a line matching '$want_text'"; failures=$((failures+1)); fi
  else
    if grep -qF "$want_text" <<< "$out"; then
      echo "  FAILED   $desc — reported '$want_text' and should not have"; failures=$((failures+1))
    else echo "  ok       $desc"; fi
  fi
}

echo "check-transitions, the Project field rules (#346):"

FIELDS_ALL=',{"name":"Delivery Tooling","field":{"name":"Workstream"}},{"name":"Low","field":{"name":"Effort"}},{"name":"High","field":{"name":"Priority"}},{"name":"Repository Change","field":{"name":"Route"}}'
FIELDS_NONE=''

# 1. past Scope with nothing set
run "a queued project with no effort is reported" "past Scope with no effort" yes \
  "$(printf '{"number":901,"title":"t","body":"x","issueType":{"name":"Project"},"subIssues":{"nodes":[]},"issueFieldValues":{"nodes":[{"name":"Q2","field":{"name":"Phase"}}]}}')"

# 2. and with them set, it is quiet
run "a queued project with its fields set is quiet" "past Scope with no effort" no \
  "$(printf '{"number":902,"title":"t","body":"x","issueType":{"name":"Project"},"subIssues":{"nodes":[]},"issueFieldValues":{"nodes":[{"name":"Q2","field":{"name":"Phase"}}%s]}}' "$FIELDS_ALL")"

# 3. THE EXEMPTION: a parent owes no route, because it has no delivery role
run "a parent at Design and Test Approach is not asked for a route" "no route" no \
  "$(printf '{"number":903,"title":"t","body":"## Requirements ## Design","issueType":{"name":"Project"},"subIssues":{"nodes":[{"number":904,"issueType":{"name":"Project"}}]},"issueFieldValues":{"nodes":[{"name":"Design and Test Approach","field":{"name":"Phase"}},{"name":"Delivery Tooling","field":{"name":"Workstream"}},{"name":"Low","field":{"name":"Effort"}},{"name":"High","field":{"name":"Priority"}}]}}')"

# 4. a work package at Development with no milestone is reported
run "a work package being built with no milestone is reported" "no milestone" yes \
  "$(printf '{"number":905,"title":"t","body":"see #903","parent":{"number":903},"issueType":{"name":"Project"},"subIssues":{"nodes":[]},"issueFieldValues":{"nodes":[{"name":"Development","field":{"name":"Phase"}},{"name":"Delivery Tooling","field":{"name":"Workstream"}},{"name":"Low","field":{"name":"Effort"}},{"name":"High","field":{"name":"Priority"}},{"name":"Repository Change","field":{"name":"Route"}}]}}')"

# 5. an unanswered post-deployment row is reported, an answered one is not
run "a blank post-deployment row is reported" "post-deployment check(s) with no answer" yes \
  "$(printf '{"number":906,"title":"t","body":%s,"parent":{"number":903},"milestone":{"title":"0.8.1"},"issueType":{"name":"Project"},"subIssues":{"nodes":[]},"issueFieldValues":{"nodes":[{"name":"Post-deployment","field":{"name":"Phase"}},{"name":"Delivery Tooling","field":{"name":"Workstream"}},{"name":"Low","field":{"name":"Effort"}},{"name":"High","field":{"name":"Priority"}},{"name":"Repository Change","field":{"name":"Route"}}]}}' "$(printf '%s' "$BLANK_CHECKS" | base64 -d | jq -Rs .)")"

# The body above is JSON-encoded with `jq -Rs`, not flattened: the rule scans
# for a heading and then for table rows, so a body whose newlines have been
# turned into spaces tests nothing. That is how this case failed first time.

echo
if [ "$failures" -eq 0 ]; then echo "all project transition tests passed."; else echo "$failures failing"; exit 1; fi
