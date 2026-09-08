#!/usr/bin/env bash
set -euo pipefail

# Tests verify.sh's test-approach check (#289), under the same
# `set -euo pipefail` verify.sh runs with.
#
# The behaviour: a project in the release milestone whose test approach has
# unticked boxes is named, with the environment that owes each. #240 shipped
# with `revoke` untested because the approach was prose and nothing could
# count it.
#
# `gh` is stubbed. The quiet case — every box ticked, and the check says
# nothing — is the one a broken check passes by accident, so it is here twice:
# once for ticked boxes and once for a milestone with no projects at all.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

# Runs verify.sh's approach check alone against a stubbed `gh`.
#   $1  the issue list rows, "<number>\t<title>" per line
#   $2  the body returned for every `gh issue view`
run_approach() {
  local list="$1" body="$2" work
  work="$(mktemp -d)"
  mkdir -p "$work/bin"
  printf '%s' "$list" > "$work/list"
  printf '%s' "$body" > "$work/body"

  cat > "$work/bin/gh" <<STUB
#!/usr/bin/env bash
# The sub-issues call decides whether the issue is a parent. Answered from
# PARENTS so one case can mix a parent and a package; 0 for everything else,
# which is what every case written before D51 expects.
case "\$*" in
  *"/sub_issues"*) n="\$*"; n="\${n#*/issues/}"; n="\${n%%/*}"
                   case " \${PARENTS:-} " in *" \$n "*) echo 1 ;; *) echo 0 ;; esac
                   exit 0 ;;
esac
for a in "\$@"; do
  [[ "\$a" == "view" ]] && { cat "$work/body"; exit 0; }
done
cat "$work/list"
exit 0
STUB
  chmod +x "$work/bin/gh"

  (
    cd "$HERE"
    PATH="$work/bin:$PATH"
    # shellcheck disable=SC1090
    source <(sed -n '/^section_boxes()/,/^}/p;/^is_parent()/,/^}/p;/^check_approach()/,/^}/p' scripts/verify.sh)
    # Both take a third argument, the detail lines. The first version of this
    # stub dropped it, and two cases failed for want of output the check was
    # producing — a harness that does not mirror the real signature tests
    # something other than the code.
    pass() { printf 'PASS %s\n%s\n' "$2" "${3:-}"; }
    fail() { printf 'FAIL %s\n%s\n' "$2" "${3:-}"; }
    declare -A LABEL
    check_approach
  )
  rm -rf "$work"
}

echo "verify-test-approach"

TAB="$(printf '\t')"

# 1 — an unticked technical test is named, with its environment
out="$(run_approach "240${TAB}Rehearsal has no access control" \
'## Test approach

### Functional user tests — Preview

None.

### Technical tests — Rehearsal

- [ ] revoke locks out an already-unlocked device
- [x] the phone is refused before a grant

## Post-deployment checks

- [ ] not a test, and must not be counted
')"
check "an unticked technical test fails the check" "FAIL" "$(awk '{print $1; exit}' <<< "$out")"
check "it says which environment owes it" "1" "$(grep -c 'Rehearsal' <<< "$out")"

# 2 — the quiet case: every box ticked, nothing said
out="$(run_approach "285${TAB}The sweeps are owned by two workstreams" \
'### Functional user tests — Preview

- [x] nothing a person uses changes

### Technical tests — Rehearsal

- [x] the size series gains a row after the deploy
')"
check "all boxes ticked passes" "PASS" "$(awk '{print $1; exit}' <<< "$out")"

# 3 — boxes outside the test approach must not count
out="$(run_approach "282${TAB}The bot plays the plural" \
'### Technical tests — Rehearsal

- [x] the regression test runs in CI

## Post-deployment checks against requirements

- [ ] JISMS is not playable
- [ ] the list has 2678 lines
')"
check "unticked post-deployment rows are not counted as tests" "PASS" "$(awk '{print $1; exit}' <<< "$out")"

# 3b — a parent owns no test approach, so it is not asked for one
# D51: the parent owns the requirements, the design and the documents; the work
# packages own the artefacts, the test approach and the post-deployment checks.
# `check-transitions.sh` has exempted a parent since D51 landed and this check
# did not, so the two tools disagreed about the same issue. The body here is a
# real parent's shape — requirements and design, and no test approach at all.
PARENTS="71"; export PARENTS
out="$(run_approach "71${TAB}Rebuild the client" \
'## Requirements

| | from | |
| --- | --- | --- |
| R1 | #123 | the client is on a supported major version |

## Design

See the design document.

## Deliveries

| # | what it delivers | milestone |
| --- | --- | --- |
| 1 | #269 Core Client UI | 1.0.0 |
')"
check "a parent with no test approach passes" "PASS" "$(awk '{print $1; exit}' <<< "$out")"
check "and is named as a parent, not counted" "1" "$(grep -c 'a parent' <<< "$out")"
unset PARENTS

# 4 — a project with no headings at all is reported, and differently
out="$(run_approach "999${TAB}A project written before the headings existed" \
'## Test approach

We will test it by using it.
')"
check "a project with no test approach headings fails" "FAIL" "$(awk '{print $1; exit}' <<< "$out")"
check "and says so, rather than claiming a count" "1" "$(grep -c 'no test approach headings' <<< "$out")"

# 5 — an empty milestone is quiet
out="$(run_approach "" "")"
check "no open projects in the milestone passes" "PASS" "$(awk '{print $1; exit}' <<< "$out")"

if (( failures )); then
  echo "  $failures check(s) failed"
  exit 1
fi
echo "  all checks passed"
