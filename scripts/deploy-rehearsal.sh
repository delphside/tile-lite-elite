#!/usr/bin/env bash
set -euo pipefail

# deploy-rehearsal.sh — deploy to the rehearsal host: the same script, the
# same images and the same steps production gets, against a machine built to
# match it (Ubuntu 24.04, x86_64, 954 MB, its own volume).
#
# Why a wrapper and not an env file you source. A sourced file leaves
# DEPLOY_HOST set in your shell, so a later plain `./scripts/deploy.sh` would
# quietly go to the rehearsal host — or, worse, a half-applied one would go
# to production while you believed otherwise. deploy.sh defaults every
# variable to production, so anything left unset falls back to the live site.
# Setting them for one command only is what makes that safe.
#
# Usage mirrors deploy.sh, plus one verb of its own:
#   ./scripts/deploy-rehearsal.sh              # deploy HEAD
#   ./scripts/deploy-rehearsal.sh <commit-ish>
#   ./scripts/deploy-rehearsal.sh reset        # empty the database and restart

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: deploy-rehearsal.sh              # deploy HEAD
       deploy-rehearsal.sh <commit-ish>
       deploy-rehearsal.sh reset        # empty the database and restart

A wrapper that points deploy.sh at the rehearsal host for one command
only, so nothing is left set in your shell. See the header comment
above for why that matters: deploy.sh defaults every variable to
production, so a half-applied environment goes live.

`reset` destroys everything on the host, including any seeded
production data (#252 R4, #315). It is run between testing phases,
not between runs.

Refuses (exit 1) when:
  - `reset` is asked for and the target looks like production
    -> "deploy-rehearsal: refusing to reset '<host>' — that is not
        rehearsal."
    The only way this fires is that rehearsal-target.sh is wrong,
    since it exports DEPLOY_HOST unconditionally and a caller cannot
    set it from outside.
  - the remote `docker compose down -v && up -d` fails
    -> "deploy-rehearsal: the reset failed — rehearsal may be down."
  - the host does not answer /health within 60s of a reset
    -> "deploy-rehearsal: it did not come back within 60s — check the
        host."

Every other refusal is deploy.sh's, which this execs: run
`./scripts/deploy.sh --help` for those.
EOF
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/rehearsal-target.sh
. "$HERE/rehearsal-target.sh"

# `reset` — clear the database and start again from empty (#252 R4).
#
# **The principle, owner 2026-09-06:** *"a good principle that test suites start
# with an empty database and add the data they need."* A suite that begins from
# empty has no shared state to collide over and no accumulated litter to
# identify — which is what let #252 descope its sweep entirely: an empty
# database has nothing left behind to sweep.
#
# **The cadence is a testing phase, not a run.** Runs accumulate within a phase
# deliberately; that is why telling one run from another is worth doing. This is
# run *between* phases.
#
# **It also takes production data off the host.** `seed-rehearsal.sh` copies a
# production snapshot here, and its own header says to treat a seeded rehearsal
# host as carrying production data. Nothing removed it until now (#315), and the
# owner ran that script by accident on 2026-09-05, which is where the
# requirement came from.
#
# Deliberately not a subcommand of `deploy.sh`: that script deploys a commit, and
# this destroys data. Sharing an entry point between the two is how a flag ends
# up on the wrong invocation.
if [[ "${1:-}" == "reset" ]]; then
  REMOTE="$DEPLOY_USER@$DEPLOY_HOST"
  SSH=(-i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)

  # **The guard exists for one failure, and it is the one `rehearsal-target.sh`
  # warns about itself**: *"two copies would eventually disagree, and the one
  # that disagreed silently would be pointing at production."* That file exports
  # DEPLOY_HOST unconditionally two lines above, so a caller cannot set it from
  # outside — which means the only way this host is production is that the
  # target file is wrong. `clean-test-accounts.sh` refuses the same way for the
  # same reason.
  case "$DEPLOY_HOST" in
    129.151.69.246|tileliteelite.com|*prod*)
      echo "deploy-rehearsal: refusing to reset '$DEPLOY_HOST' — that is not rehearsal." >&2
      exit 1 ;;
  esac

  echo "==> Resetting rehearsal ($DEPLOY_HOST) to an empty database"
  echo "    Everything on it is destroyed, including any seeded production data."
  # `down -v` removes the volume, which is the database. `up -d` starts the
  # same images again; the server applies its migrations on boot, so an empty
  # volume comes back as an empty *schema* rather than an empty file the server
  # cannot open. `--migrate-only` is deploy.sh's business, not this script's.
  ssh "${SSH[@]}" "$REMOTE"     "cd ~/$DEPLOY_REMOTE_DIR && docker compose down -v && docker compose up -d"     || { echo "deploy-rehearsal: the reset failed — rehearsal may be down." >&2; exit 1; }

  echo "==> Waiting for it to answer"
  for _ in $(seq 1 30); do
    if curl -sf --max-time 5 "$TARGET_URL/health" > /dev/null 2>&1; then
      echo "    $(curl -sf --max-time 5 "$TARGET_URL/health")"
      echo "==> Rehearsal is empty and running. A suite can start from here."
      exit 0
    fi
    sleep 2
  done
  echo "deploy-rehearsal: it did not come back within 60s — check the host." >&2
  exit 1
fi

# **Not wired for #328, deliberately.** `exec` replaces this process, so an
# EXIT trap set here never fires -- the record would say `run started` and
# never how it ended, which is worse than no record at all. `deploy.sh`
# writes the run, and its `args` carry what was asked for.
exec "$HERE/deploy.sh" "$@"
