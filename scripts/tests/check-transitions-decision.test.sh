#!/usr/bin/env bash
set -euo pipefail

# check-transitions-decision.test.sh — the Decision rules in check-transitions.sh.
#
# A Decision has no Stage and no Phase. Open and closed is its whole state
# machine, which is what lets `closed` mean *applied* rather than *answered* —
# the distinction the glossary's decision index could not express, and the
# reason #298 exists. So the rules under test are the one transition it has.
#
# `gh` is stubbed, so the only input is the canned JSON. The stub answers two
# different queries: the script asks for open issues, then for closed ones, and
# it tells them apart the same way the script does — by `states:CLOSED` in the
# query text.
#
# Run under the same `set -euo pipefail` the script runs under: a harness
# missing pipefail once hid a silent abort that reached a production deploy.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
BIN="$DIR/bin"; mkdir -p "$BIN"

# Bodies are written as files and base64'd into the JSON, because the thing
# being tested is heading-and-newline structure. Building them inline as escaped
# strings is how a fixture comes to test something other than what it looks like.
mkbody() { printf '%s' "$1" | base64 -w0; }

SETTLED="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Open actions

- [x] (Steve) choose
- [x] (Claude) record it
')"

IN_PROGRESS="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Open actions

- [x] (Steve) choose
- [ ] (Claude) record it
')"

UNDECIDED="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

_No response_

### Open actions

- [ ] (Steve) choose
')"

OLD_HEADING="$(mkbody '### Context & Proposal

meat or fish

### Agreed Decision

meat

### Action Items

- [ ] Action item 1
- [ ] Action item 2
')"

run() {
  local desc="$1" want_exit="$2" want_text="$3" open_nodes="$4" closed_nodes="$5"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *states:CLOSED*)
      cat <<'JSON'
{"data":{"repository":{"issues":{"nodes":[$closed_nodes]}}}}
JSON
      exit 0 ;;
  esac
done
cat <<'JSON'
{"data":{"repository":{"issues":{"nodes":[$open_nodes]}}}}
JSON
EOF
  chmod +x "$BIN/gh"
  local out got=0
  out="$(PATH="$BIN:$PATH" "$HERE/check-transitions.sh" 2>&1)" || got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "  FAILED   $desc (expected exit $want_exit, got $got)"; failures=$((failures+1)); return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<< "$out"; then
    echo "  FAILED   $desc (exit $got, but no line matched '$want_text')"
    printf '%s\n' "$out" | sed 's/^/           /'
    failures=$((failures+1)); return
  fi
  if [ -z "$want_text" ] && grep -q '^  #' <<< "$out"; then
    echo "  FAILED   $desc (expected nothing reported)"
    printf '%s\n' "$out" | sed 's/^/           /'
    failures=$((failures+1)); return
  fi
  echo "  ok       $desc"
}

# The open query selects body via jq from the node, so the body has to be real
# text there; the closed query base64s it in the script. Both take plain text.
#
# The third argument is `Decision State`. Empty means the field is unset, which
# is itself a case. Not because it hides the issue — the board grows a "No
# Decision State" column and shows it there — but because unset is not one of
# the three states, and every open decision has at least been asked. It is an
# unfiled issue in a column that means nothing, not a missing one.
open_dec() {  # $1 = number, $2 = base64 body, $3 = Decision State or ""
  local fields=""
  [ -n "${3:-}" ] && fields="$(printf '{"name":"%s","field":{"name":"Decision State"}}' "$3")"
  printf '{"number":%s,"title":"d","body":%s,"issueType":{"name":"Decision"},"issueFieldValues":{"nodes":[%s]}}' \
    "$1" "$(printf '%s' "$2" | base64 -d | jq -Rs .)" "$fields"
}
closed_dec() { open_dec "$1" "$2" "${3:-}"; }

echo "open decisions:"
run "settled and every action done is reported"        1 "mark it Actioned"            "$(open_dec 900 "$SETTLED" Decided)"     ""
run "an action still open is left alone"               0 ""                            "$(open_dec 901 "$IN_PROGRESS" Decided)" ""
run "no agreed decision yet is left alone"             0 ""                            "$(open_dec 902 "$UNDECIDED" Asked)"     ""
run "an unreadable actions heading is reported as that" 1 "invisible to actions.py"    "$(open_dec 903 "$OLD_HEADING" Decided)" ""

# `Decision State` and the body are two records of one fact. The board column is
# dragged in a browser and the body is not, so they drift in both directions and
# both are tested.
echo "the state field against the body:"
run "agreed but still marked Asked is reported"        1 "still marked Asked"          "$(open_dec 904 "$IN_PROGRESS" Asked)"   ""
run "marked Decided with nothing agreed is reported"   1 "no agreed decision in the body" "$(open_dec 905 "$UNDECIDED" Decided)" ""
# D44: applied and read are different moments, so this is the normal state of a
# decision waiting to be read — not an error. It was reported until 2026-09-05.
run "marked Actioned while open is left alone"         0 ""                            "$(open_dec 906 "$SETTLED" Actioned)"    ""
run "no Decision State at all is reported"             1 "no Decision State"           "$(open_dec 907 "$IN_PROGRESS" "")"      ""
# D45. `Feedback Provided` means both have spoken and it is not settled yet, so an
# Agreed Decision written there is the state lagging the body — the mirror of
# the Asked rule.
run "Feedback Provided with nothing agreed is left alone"  0 ""                            "$(open_dec 908 "$UNDECIDED" "Feedback Provided")" ""
run "Feedback Provided with a decision written is reported" 1 "Documented Ready for Sign-Off"         "$(open_dec 909 "$IN_PROGRESS" "Feedback Provided")" ""
# Documented Ready for Sign-Off exists so the owner has something to sign off *against*.
run "Documented Ready for Sign-Off with a decision is left alone" 0 ""                            "$(open_dec 916 "$IN_PROGRESS" "Documented Ready for Sign-Off")" ""
run "Documented Ready for Sign-Off with nothing agreed is reported" 1 "nothing is documented"     "$(open_dec 917 "$UNDECIDED" "Documented Ready for Sign-Off")" ""

echo "closed decisions:"
run "closed and complete is left alone"                0 ""                            "" "$(closed_dec 910 "$SETTLED" Actioned)"
run "closed with no agreed decision is reported"       1 "no agreed decision"          "" "$(closed_dec 911 "$UNDECIDED" Actioned)"
run "closed with an action still open is reported"     1 "1 action(s) still open"      "" "$(closed_dec 912 "$IN_PROGRESS" Actioned)"
run "closed with an unreadable heading is reported"    1 "no 'Open actions' heading"   "" "$(closed_dec 913 "$OLD_HEADING" Actioned)"

# Actioned and closed coincide — owner, 2026-09-05. Tested from the closed side
# as well as the open one, because a biconditional asserted in one direction is
# half a rule.
run "closed but marked Decided is reported"            1 "a closed decision is Actioned" "" "$(closed_dec 914 "$SETTLED" Decided)"
run "closed with no state is reported"                 1 "marked 'unset'"              "" "$(closed_dec 915 "$SETTLED" "")"

echo "other types:"
run "a requirement is not judged as a decision"        0 "" \
  '{"number":920,"title":"r","body":"","issueType":{"name":"Requirement"},"issueFieldValues":{"nodes":[]}}' ""

echo
echo "duplicate decision numbers:"

# #339 R2. The number is typed into the title by hand and nothing compared them,
# so #333 and #337 were both D48 on 2026-09-06. Its own stub, because this rule
# reads `gh issue list` rather than the two graphql queries above.
#
# The quiet case is asserted as well as the loud one: a check that reports
# nothing is indistinguishable from a broken one unless the silence is pinned.
run_dupes() {
  local desc="$1" want_exit="$2" want_text="$3" titles="$4"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"issue list"*)
    printf '%b' '$titles'
    exit 0 ;;
esac
for a in "\$@"; do
  case "\$a" in
    *states:CLOSED*) echo '{"data":{"repository":{"issues":{"nodes":[]}}}}'; exit 0 ;;
  esac
done
echo '{"data":{"repository":{"issues":{"nodes":[]}}}}'
EOF
  chmod +x "$BIN/gh"
  local out got=0
  out="$(PATH="$BIN:$PATH" "$HERE/check-transitions.sh" 2>&1)" || got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "  FAILED   $desc (expected exit $want_exit, got $got)"; failures=$((failures+1)); return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<< "$out"; then
    echo "  FAILED   $desc (exit $got, but no line matched '$want_text')"
    printf '%s\n' "$out" | sed 's/^/           /'; failures=$((failures+1)); return
  fi
  if [ -z "$want_text" ] && grep -q '^  #' <<< "$out"; then
    echo "  FAILED   $desc (expected nothing reported)"
    printf '%s\n' "$out" | sed 's/^/           /'; failures=$((failures+1)); return
  fi
  echo "  ok       $desc"
}

DISTINCT='333\t[Decision]: D48 · one\n337\t[Decision]: D49 · two\n376\t[Decision]: D53 · three\n'
CLASHING='333\t[Decision]: D48 · one\n337\t[Decision]: D48 · two\n376\t[Decision]: D53 · three\n'

run_dupes "distinct numbers report nothing"        0 ""                       "$DISTINCT"
run_dupes "two decisions on one number is reported" 1 "D48 is used by #333 #337" "$CLASHING"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all decision transition tests passed."
