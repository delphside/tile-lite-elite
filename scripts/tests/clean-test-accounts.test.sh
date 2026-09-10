#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/clean-test-accounts.sh under the same `set -euo pipefail` it
# runs with.
#
# The case that matters is the one that reads as success today: a cleaner
# pointed at something it cannot reach must be **loud and non-zero**, not
# "removed 0". That is #128's defect, and it is the same shape as the milestone
# gate #207 fixed — a check that cannot tell "nothing to do" from "not looking".
#
# The admin CLI is stubbed, so nothing real is touched. Every case runs against
# a scripted listing.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CLEAN="$HERE/clean-test-accounts.sh"
failures=0

# Builds a PATH holding a stubbed `docker` (preview's route) whose `users list`
# answers with $LISTING and whose `users delete` obeys $DELETE_EXIT.
setup() {
  DIR="$(mktemp -d)"; BIN="$DIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"users list"*)   [[ "${LIST_EXIT:-0}" == 0 ]] || { echo "connection refused" >&2; exit 1; }
                    printf '%s' "${LISTING:-[]}" ;;
  *"users delete"*) echo "$*" >> "$CALLS"; exit "${DELETE_EXIT:-0}" ;;
  *)                : ;;
esac
STUB
  chmod +x "$BIN/docker"
  CALLS="$DIR/calls"; : > "$CALLS"; export CALLS
  PATH="$BIN:$PATH"
  unset LIST_EXIT DELETE_EXIT 2>/dev/null || true
  LISTING='[]'; export LISTING
}
teardown() { rm -rf "$DIR"; }

run() { "$CLEAN" "$@" 2>&1; }

check() {  # name, expected, actual
  if [[ "$2" == "$3" ]]; then echo "ok   $1"
  else echo "FAIL $1"; echo "     wanted: $2"; echo "     got:    $3"; failures=$((failures + 1)); fi
}
status_of() { local s=0; "$@" > /dev/null 2>&1 || s=$?; echo "$s"; }

# --- the safety rule -----------------------------------------------------------
setup
# **`1`, not `3`** — D46, and #330. The refusal is the strongest stop this script
# has: it carries on with nothing and deletes nothing, which is `fatal` in the
# scheme. `3` means *it went wrong and the run continued*, which is the opposite.
#
# The caller's need to tell "refused because wrong environment" from any other
# failure is met by the message, which D46 put there deliberately rather than in
# the status. Nothing read the `3`: `e2e-clean.sh` execs and passes the status
# through, and Playwright's teardown catches any non-zero and warns without
# failing the suite.
check "production is refused, by name"   "1" "$(status_of "$CLEAN" --prefix e2e- --target production)"
check "production is refused, by URL"    "1" "$(status_of "$CLEAN" --prefix e2e- --target https://tileliteelite.com)"
check "an unrecognised target is refused rather than guessed" \
                                         "1" "$(status_of "$CLEAN" --prefix e2e- --target https://example.invalid)"
check "nothing was deleted while refusing" "0" "$(grep -c . "$CALLS" || true)"
teardown

# --- the defect this exists to remove -----------------------------------------
setup
export LIST_EXIT=1
out="$(run --prefix e2e- --target http://localhost:8081 || true)"
check "unreachable target is loud"       "yes" \
  "$(case "$out" in *"could not reach"*) echo yes ;; *) echo "$out" ;; esac)"
check "unreachable target is non-zero"   "1" \
  "$(status_of "$CLEAN" --prefix e2e- --target http://localhost:8081)"
teardown

# --- ordinary success ----------------------------------------------------------
setup
LISTING='[{"display_name":"e2e-alice"},{"display_name":"e2e-bob"},{"display_name":"steve"}]'
export LISTING
out="$(run --prefix e2e- --target http://localhost:8081)"
check "removes only the matching accounts" "2" "$(grep -c 'users delete' "$CALLS" || true)"
# `grep steve` alone matches the repository path in every stubbed argument
# list — /home/steve/… — so the account has to be matched as the delete's
# argument, not anywhere on the line.
check "and leaves the others alone"        "0" "$(grep -c 'users delete steve$' "$CALLS" || true)"
check "and says how many"                  "yes" \
  "$(case "$out" in *"removed 2 of 2"*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# --- nothing to clean is success, quietly -------------------------------------
setup
LISTING='[{"display_name":"steve"}]'; export LISTING
check "no matches, nothing expected: exit 0" "0" \
  "$(status_of "$CLEAN" --prefix e2e- --target http://localhost:8081)"
teardown

# --- but not when the caller says it made some --------------------------------
setup
LISTING='[{"display_name":"steve"}]'; export LISTING
check "no matches but --expect 3: non-zero" "1" \
  "$(status_of "$CLEAN" --prefix e2e- --target http://localhost:8081 --expect 3)"
out="$(run --prefix e2e- --target http://localhost:8081 --expect 3 || true)"
check "and says the caller disagrees"      "yes" \
  "$(case "$out" in *"found none"*) echo yes ;; *) echo "$out" ;; esac)"
teardown

# --- a refused delete is a failure, not a shrug -------------------------------
setup
LISTING='[{"display_name":"e2e-alice"}]'; export LISTING
export DELETE_EXIT=1
check "a delete that is refused exits non-zero" "1" \
  "$(status_of "$CLEAN" --prefix e2e- --target http://localhost:8081)"
teardown

if (( failures )); then echo "$failures test(s) failed" >&2; exit 1; fi
echo
echo "All clean-test-accounts tests passed."
