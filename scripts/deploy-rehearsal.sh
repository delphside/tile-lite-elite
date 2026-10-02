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
# Usage mirrors deploy.sh exactly:
#   ./scripts/deploy-rehearsal.sh              # deploy HEAD
#   ./scripts/deploy-rehearsal.sh <commit-ish>

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/rehearsal-target.sh
. "$HERE/rehearsal-target.sh"
exec "$HERE/deploy.sh" "$@"
