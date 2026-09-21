#!/usr/bin/env bash
set -euo pipefail

# Tests `deploy-rehearsal.sh reset` — the guard, and that it does not fall
# through to a deploy (#252 R4).
#
# The destructive half is not exercised: it runs `docker compose down -v` over
# ssh, and a test that stubs both proves the stub. What is worth pinning is that
# it **refuses a host that is not rehearsal** and that `reset` never reaches
# `deploy.sh` — a verb that silently deployed instead of resetting, or reset
# production instead of rehearsal, are the two ways this can be badly wrong.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
check() {
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; failures=$((failures+1)); fi
}

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT; mkdir -p "$DIR/bin" "$DIR/scripts"
# ssh, curl and docker must never be reached in a refusal; if they are, say so.
for c in ssh curl docker; do
  printf '#!/usr/bin/env bash\necho "REACHED %s" >&2\nexit 0\n' "$c" > "$DIR/bin/$c"
  chmod +x "$DIR/bin/$c"
done

# A copy of the script beside a **wrong target file**, which is the only way the
# host can be production: `rehearsal-target.sh` exports DEPLOY_HOST
# unconditionally, so a caller cannot set it from outside — the first version of
# this test tried and the guard never fired. Its own header names this failure:
# "two copies would eventually disagree, and the one that disagreed silently
# would be pointing at production."
cp "$HERE/scripts/deploy-rehearsal.sh" "$DIR/scripts/"
cat > "$DIR/scripts/deploy.sh" <<'STUB'
#!/usr/bin/env bash
echo "REACHED deploy.sh" >&2
STUB
chmod +x "$DIR/scripts/deploy.sh"

wrong_target() {   # $1 = the host the target file wrongly points at
  cat > "$DIR/scripts/rehearsal-target.sh" <<TARGET
export DEPLOY_ENV=rehearsal
export DEPLOY_HOST=$1
export DEPLOY_USER=ubuntu
export DEPLOY_SSH_KEY=/dev/null
export DEPLOY_REMOTE_DIR=tile-lite-elite
export TARGET_URL=https://example.invalid
TARGET
}

echo "deploy-rehearsal reset"

# 1 — a target file pointing at production is refused, and nothing is reached
wrong_target 129.151.69.246
out="$(PATH="$DIR/bin:$PATH" "$DIR/scripts/deploy-rehearsal.sh" reset 2>&1 || true)"
check "production by IP is refused"    "1" "$(grep -c 'refusing to reset' <<< "$out")"
check "and nothing was run against it" "0" "$(grep -c 'REACHED' <<< "$out")"

wrong_target tileliteelite.com
out="$(PATH="$DIR/bin:$PATH" "$DIR/scripts/deploy-rehearsal.sh" reset 2>&1 || true)"
check "production by hostname is refused" "1" "$(grep -c 'refusing to reset' <<< "$out")"

# 2 — the real rehearsal host is not refused. Stubbed ssh, so nothing is
#     destroyed; what is asserted is that it got past the guard.
wrong_target 129.151.84.183
out="$(PATH="$DIR/bin:$PATH" "$DIR/scripts/deploy-rehearsal.sh" reset 2>&1 || true)"
check "the rehearsal host is not refused" "0" "$(grep -c 'refusing to reset' <<< "$out")"
check "and it says what it is destroying" "1" "$(grep -c 'including any seeded production data' <<< "$out")"

# 3 — `reset` is intercepted, never passed through to deploy.sh as a commit-ish
check "reset never reaches deploy.sh" "0" "$(grep -c 'REACHED deploy.sh' <<< "$out")"
check "the branch exits rather than falling through" "1" \
  "$(awk '/if \[\[ "\$\{1:-\}" == "reset" \]\]/,/^fi$/' "$HERE/scripts/deploy-rehearsal.sh" | grep -c 'exit 0')"

# 4 — a verb nobody knows about is not a tool.
# Asserted as "at least once", not "exactly once": the script now says it in
# its header and again in `--help` (#329 R3), and an exact count made adding
# the second one look like a regression.
check "usage mentions reset" "yes" \
  "$(grep -q 'deploy-rehearsal.sh reset' "$HERE/scripts/deploy-rehearsal.sh" && echo yes || echo no)"

echo
if (( failures )); then echo "  $failures check(s) failed"; exit 1; fi
echo "  all checks passed"
