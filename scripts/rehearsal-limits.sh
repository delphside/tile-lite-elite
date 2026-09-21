#!/usr/bin/env bash
set -euo pipefail
# A record of this run that outlives the terminal -- #328.
# shellcheck source=scripts/run-log.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-log.sh"
run_log_start rehearsal-limits.sh "$@"



# rehearsal-limits.sh — switch rehearsal between production's rate limits and
# ones a regression suite can survive.
#
# **Why a switch and not simply relaxing them.** Rehearsal's whole value is
# being production-shaped, and `check-rate-limits.sh` exists to prove the
# limiter enforces *production's* numbers there. Leaving rehearsal permanently
# relaxed would not break that check loudly; it would make it pass against
# 6000 registrations a minute and mean nothing. So the relaxation is explicit,
# temporary, and visible.
#
# **Why it is needed at all.** Registration is 2 a minute with a burst of 3
# (`docs/4.1`), and the e2e suite registers an account per test. Measured
# 2026-09-19, same code and same host, limits the only difference:
#
#   preview, relaxed limits      0 failed, 31 passed
#   preview, production limits   24 failed, 7 passed
#   rehearsal, production limits 21 failed, 10 passed
#
# A refused registration looks exactly like a broken sign-up, which is the same
# confusion #286 records about the access gate one layer out.
#
# The numbers match `docker-compose.preview.yml`, which has carried them since
# preview was built — this is that arrangement, made available to a host whose
# defaults are production's.
#
# Usage:
#   ./scripts/rehearsal-limits.sh show
#   ./scripts/rehearsal-limits.sh regression   # relax, for an e2e run
#   ./scripts/rehearsal-limits.sh production   # restore, and leave it restored
#
# `.env` is created by hand and `deploy.sh` never touches it, so a setting
# survives a redeploy — which is the hazard this is shaped around. Restore.

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${REHEARSAL_SSH_HOST:-tile-lite-elite-rehearsal}"
ENV_FILE='~/tile-lite-elite/.env'
COMPOSE='~/tile-lite-elite/docker-compose.yml'

# The keys this script owns. Anything else in `.env` is left alone: it holds
# the access key and the secrets Compose reads, and a careless rewrite of it
# takes rehearsal off the air.
KEYS=(
  TILE_LITE_ELITE_LIMIT_REGISTER_PER_MIN
  TILE_LITE_ELITE_LIMIT_REGISTER_BURST
  TILE_LITE_ELITE_LIMIT_AUTH_PER_MIN
  TILE_LITE_ELITE_LIMIT_AUTH_BURST
  TILE_LITE_ELITE_LIMIT_SESSION_PER_MIN
  TILE_LITE_ELITE_LIMIT_SESSION_BURST
  TILE_LITE_ELITE_LIMIT_GLOBAL_PER_MIN
  TILE_LITE_ELITE_LIMIT_GLOBAL_BURST
)
RELAXED=(6000 1000 6000 1000 6000 1000 60000 10000)

on_host() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

case "${1:-show}" in
  show)
    echo "==> rehearsal rate limits, as \`.env\` sets them"
    if ! out="$(on_host "grep -E '^TILE_LITE_ELITE_LIMIT_' $ENV_FILE 2>/dev/null || true")"; then
      echo "rehearsal-limits: could not reach $HOST" >&2; exit 1
    fi
    if [[ -z "$out" ]]; then
      echo "    none set — production's defaults are in force (register 2/min, burst 3)"
    else
      printf '    %s\n' $out
      echo
      echo "    Relaxed. Run './scripts/rehearsal-limits.sh production' when the run is done,"
      echo "    or check-rate-limits.sh will pass against numbers nobody ships."
    fi
    ;;

  regression)
    # Removed then appended, so running this twice does not accumulate copies
    # and a partly-set file lands wholly set.
    cmd=""
    for i in "${!KEYS[@]}"; do
      cmd+="sed -i '/^${KEYS[$i]}=/d' $ENV_FILE; "
      cmd+="echo '${KEYS[$i]}=${RELAXED[$i]}' >> $ENV_FILE; "
    done
    on_host "$cmd docker compose -f $COMPOSE up -d server" >/dev/null
    echo "==> rehearsal relaxed for a regression run — restore with: $0 production"
    ;;

  production)
    cmd=""
    for key in "${KEYS[@]}"; do cmd+="sed -i '/^${key}=/d' $ENV_FILE; "; done
    on_host "$cmd docker compose -f $COMPOSE up -d server" >/dev/null
    echo "==> rehearsal restored to production's limits"
    ;;

  *)
    echo "usage: $0 [show|regression|production]" >&2; exit 2 ;;
esac
