#!/usr/bin/env bash
# Where the rehearsal environment lives. Sourced by deploy-rehearsal.sh and
# rollback-rehearsal.sh so the host, key and URL are defined once — two
# copies would eventually disagree, and the one that disagreed silently
# would be pointing at production.
#
# Not meant to be sourced into your own shell: the wrappers run it in their
# own process so nothing leaks into a later plain ./scripts/deliver/deploy.sh, which
# defaults every one of these to production.
export DEPLOY_ENV=rehearsal
export DEPLOY_HOST=129.151.84.183
export DEPLOY_USER=ubuntu
export DEPLOY_SSH_KEY="$HOME/.ssh/oracle_tile_lite_elite_rehearsal"
export DEPLOY_REMOTE_DIR=tile-lite-elite
export TARGET_URL=https://129.151.84.183.sslip.io
# Rehearsal's .env, in Turpin's state folder, and how a change to it is applied:
# Compose against the current deploy, under the environment's lock. It refuses
# where there is no current deploy or the lock is held. The rehearsal-* scripts
# and seed-rehearsal.sh read these, so the path is named here and nowhere else.
export REHEARSAL_ENV_FILE=/var/lib/turpin/tile-lite-elite/rehearsal/.env
export REHEARSAL_COMPOSE="turpin-host compose tile-lite-elite rehearsal"
