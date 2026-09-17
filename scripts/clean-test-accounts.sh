#!/usr/bin/env bash
set -euo pipefail

# clean-test-accounts.sh — remove the accounts a test tool created, from the
# environment it actually ran against.
#
# Two tools created accounts in one environment and tidied up in another, or not
# at all, and both reported success while doing it (#128, #148). This is the one
# cleaner they both call, so the next test tool does not invent a third way to
# leave litter behind.
#
#   ./scripts/clean-test-accounts.sh --prefix e2e-  --target http://localhost:8081
#   ./scripts/clean-test-accounts.sh --prefix ratecheck- --target "$REHEARSAL_URL" --expect 3
#
# **It refuses production.** A cleaner that deletes accounts by prefix has no
# business anywhere near real users, and the safest place to enforce that is
# here rather than in each caller's argument handling.
#
# **Cleaning nothing is only success if there was nothing to clean.** Three
# outcomes, and the middle one is the bug this exists to remove:
#
#   found some, removed them          -> 0, says how many
#   found none, and none were made    -> 0, quietly
#   could not reach the target        -> non-zero, loudly
#   caller made N and none were found -> non-zero, loudly   (--expect)

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PREFIX=""
TARGET=""
EXPECT=""

while (( $# )); do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
    --expect) EXPECT="${2:?--expect needs a value}"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "clean-test-accounts: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$PREFIX" ]] || { echo "clean-test-accounts: --prefix is required" >&2; exit 2; }
[[ -n "$TARGET" ]] || { echo "clean-test-accounts: --target is required" >&2; exit 2; }

# Which environment a URL names. Derived rather than passed, because the caller
# knows what it *pointed the test at* and should not also have to know what that
# machine is called — the mapping belongs in one place.
classify_target() {
  case "$1" in
    local|dev)                                        echo local ;;
    preview)                                          echo preview ;;
    rehearsal)                                        echo rehearsal ;;
    production|prod)                                  echo production ;;
    *localhost:8081*|*127.0.0.1:8081*)                echo preview ;;
    *localhost:8080*|*localhost:3000*|*127.0.0.1:*)   echo local ;;
    *129.151.84.183*|*rehearsal.tileliteelite.com*)   echo rehearsal ;;
    *tileliteelite.com*|*129.151.69.246*)             echo production ;;
    *)                                                echo unknown ;;
  esac
}

ENV_NAME="$(classify_target "$TARGET")"

# **Exit `1`, which is fatal** — D46, and `docs/4.8`. This was `3` until
# 2026-09-10, and `3` in the scheme means *it went wrong and the run continued*.
# This refusal is the opposite: it is the strongest stop the script has, it
# carries on with nothing, and it is the reason the script exists at all.
#
# The distinction a caller wants — refused because wrong environment, rather
# than failed for some other reason — lives in the **message**, which D46 placed
# there deliberately so the status could stay a severity. Both messages below
# say which case fired and why.
#
# The collision was mine: D46's survey read `deploy.sh`, `verify.sh`,
# `ci-status.sh` and `check-release-version.sh`, and not this file, then
# reported a clean field. #330.
case "$ENV_NAME" in
  production)
    echo "clean-test-accounts: refusing to run against production." >&2
    echo "  A cleaner that deletes accounts by prefix must never be pointed at real users." >&2
    exit 1
    ;;
  unknown)
    echo "clean-test-accounts: cannot tell which environment '$TARGET' is." >&2
    echo "  Refusing rather than guessing — a wrong guess deletes from the wrong place." >&2
    exit 1
    ;;
esac

# How the admin CLI is reached, which differs per environment because
# `/admin/*` only accepts connections from the container's own loopback
# (docs/3.4). That is why #148's "the admin CLI already does the work" does not
# hold for a script running on a laptop against a remote host.
admin() {
  case "$ENV_NAME" in
    local)     "$REPO_DIR/scripts/admin.sh" "$@" ;;
    preview)   docker compose -f "$REPO_DIR/docker-compose.preview.yml" exec -T server \
                 tile-lite-elite-admin "$@" ;;
    # `-n` redirects ssh's stdin from /dev/null. Without it, an ssh run inside
    # a `while read` loop consumes the lines the loop has not read yet — so the
    # cleaner deleted exactly **one** game and **one** account per run, however
    # many matched, and reported "1 of 9" as though the rest had been refused.
    # Measured 2026-09-17 against rehearsal. `deploy.sh` carries the same fix
    # and the same note; this is the second place to need it.
    rehearsal) ssh -n -o BatchMode=yes tile-lite-elite-rehearsal \
                 "docker compose -f ~/tile-lite-elite/docker-compose.yml exec -T server tile-lite-elite-admin $*" ;;
  esac
}

# Reachability is checked before anything is deleted, so "could not reach it"
# and "nothing to clean" cannot be confused — which is the whole defect.
if ! LISTING="$(admin --json users list 2>&1)"; then
  echo "clean-test-accounts: could not reach $ENV_NAME to list accounts." >&2
  printf '  %s\n' "$LISTING" >&2
  exit 1
fi

MATCHING="$(printf '%s' "$LISTING" \
  | jq -r --arg p "$PREFIX" '.[] | select(.display_name | startswith($p)) | .display_name' \
  2>/dev/null || true)"

COUNT="$(printf '%s' "$MATCHING" | grep -c . || true)"

if (( COUNT == 0 )); then
  if [[ -n "$EXPECT" ]] && (( EXPECT > 0 )); then
    echo "clean-test-accounts: expected $EXPECT account(s) matching '$PREFIX' on $ENV_NAME, found none." >&2
    echo "  The caller says it created them, so either it cleaned the wrong place or they were never made." >&2
    exit 1
  fi
  echo "clean-test-accounts: nothing matching '$PREFIX' on $ENV_NAME"
  exit 0
fi

# Games first. An account holding a game is refused by the retention rule, and
# a signed-in one by #82 — both correct, and both would otherwise look like the
# cleaner failing.
# **The games first, and only the ones that are wholly this suite's.**
#
# An account holding a game is refused by the retention rule, so a run that
# leaves a game behind leaves its accounts undeletable — permanently, because
# nothing here ever removed a game. Measured 2026-09-17 against rehearsal:
# **0 of 9 removed**, twice, first blamed on sessions and then on games.
#
# **Every human seat must match the prefix.** That is the safe rule and it is
# #252's own argument: test accounts play each other, so a game a test account
# holds is wholly test-owned by construction. A game with one real player in it
# is left alone and its test accounts stay — which is the right way round, since
# the alternative deletes somebody's game.
GAMES_JSON="$(admin --json games list 2>/dev/null || true)"
GAME_IDS="$(printf '%s' "$GAMES_JSON" | PREFIX="$PREFIX" python3 -c '
import json, os, sys
prefix = os.environ["PREFIX"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
games = data if isinstance(data, list) else data.get("games", [])
for game in games:
    humans = [p for p in game.get("participants", []) if p.get("kind") == "human"]
    names = [p.get("display_name") or "" for p in humans]
    if humans and all(n.startswith(prefix) for n in names):
        print(game["id"])
' 2>/dev/null || true)"
GAMES_REMOVED=0
while IFS= read -r gid; do
  [[ -n "$gid" ]] || continue
  admin games delete "$gid" > /dev/null 2>&1 && GAMES_REMOVED=$(( GAMES_REMOVED + 1 )) \
    || echo "clean-test-accounts: could not delete game '$gid'" >&2
done <<< "$GAME_IDS"
(( GAMES_REMOVED > 0 )) && echo "clean-test-accounts: removed $GAMES_REMOVED game(s) held only by '$PREFIX' accounts"

#
# **Signed out, then deleted.** The refusal for a live session is #82 working,
# and `users sign-out` exists to answer it — #295 built it for exactly this. Not
# using it meant a suite that ended with sessions open left every account behind:
# measured 2026-09-17 against rehearsal, **0 of 9 removed**, which reads as the
# cleaner being broken rather than as accounts still being signed in.
#
# Sign-out first rather than delete-then-retry: it costs one call either way,
# and a delete that fails for the *other* reason — the account still holds a
# game — then says so truthfully instead of being tried twice.
REMOVED=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  admin users sign-out "$name" > /dev/null 2>&1 || true
  admin users delete "$name" > /dev/null 2>&1 && REMOVED=$(( REMOVED + 1 )) \
    || echo "clean-test-accounts: could not delete '$name' — it still holds a game" >&2
done <<< "$MATCHING"

echo "clean-test-accounts: removed $REMOVED of $COUNT account(s) matching '$PREFIX' on $ENV_NAME"

if (( REMOVED < COUNT )); then exit 1; fi
if [[ -n "$EXPECT" ]] && (( REMOVED < EXPECT )); then
  echo "clean-test-accounts: caller expected $EXPECT, removed $REMOVED" >&2
  exit 1
fi
