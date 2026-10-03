#!/usr/bin/env bash
# Where the rehearsal environment lives. Sourced by deploy-rehearsal.sh and
# rollback-rehearsal.sh so the host, key and URL are defined once — two
# copies would eventually disagree, and the one that disagreed silently
# would be pointing at production.
#
# Not meant to be sourced into your own shell: the wrappers run it in their
# own process so nothing leaks into a later plain ./scripts/deploy.sh, which
# defaults every one of these to production.
export DEPLOY_ENV=rehearsal
export DEPLOY_HOST=129.151.84.183
export DEPLOY_USER=ubuntu
export DEPLOY_SSH_KEY="$HOME/.ssh/oracle_tile_lite_elite_rehearsal"
export DEPLOY_REMOTE_DIR=tile-lite-elite
export TARGET_URL=https://129.151.84.183.sslip.io
