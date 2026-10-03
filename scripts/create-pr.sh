#!/usr/bin/env bash
set -euo pipefail

# create-pr.sh — open a pull request, and leave the board agreeing with it.
#
# **Every pull request opened without this script tonight has had a wrong or
# missing `PR State`.** #401 sat in *Approved* after merging because nothing
# ran `sync-pr-state.sh` between the merge and the next `verify.sh` --
# fixed by wiring the sync into `merge-to-release.sh`. #410 sat *unset* from
# the moment it was created, because creation has no equivalent choke point:
# a pull request is opened with a bare `gh pr create` call, wherever the
# script happened to be written, and nothing downstream of that one call
# corrects the board until something else happens to run `sync-pr-state.sh`.
# The owner noticed both times; the tooling should have.
#
# **This is the choke point creation was missing.** Use it instead of a bare
# `gh pr create` from here on, the same way `merge-to-release.sh` is used
# instead of a bare `gh pr merge`.
#
#   scripts/create-pr.sh --base main --head <branch> \
#     --title "..." --body-file /path/to/body.md
#
# `--reviewer` defaults to `SteveStyle`, never `stephenmor` — `docs/4.8`
# names that trap: `gh pr create --reviewer` accepts a login it cannot use,
# prints the failure on stderr, and creates the pull request anyway,
# requesting nobody. Passing `--reviewer` explicitly overrides the default.
#
# Exits 2 on a usage error, 1 if `gh pr create` itself fails. The board
# correction after a successful create is non-fatal, the same shape as
# `merge-to-release.sh`'s: creating the pull request already happened and
# cannot be undone by a board field, so a sync failure prints where to run
# it by hand rather than failing the whole call.

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
usage: create-pr.sh --base <branch> --head <branch> --title <title>
                     --body-file <path> [--reviewer <login>] [gh pr create args...]

Wraps `gh pr create` and corrects the board's PR State afterward, which
creation otherwise leaves unset until something else happens to run
sync-pr-state.sh. --reviewer defaults to SteveStyle.

Any additional arguments are passed through to `gh pr create` unchanged.

Refuses (exit 2) when --base, --head, --title or --body-file is missing.
Exits 1 if `gh pr create` itself refuses.
USAGE
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEWER="SteveStyle"
ARGS=()
BASE="" HEAD="" TITLE="" BODY_FILE=""

while (( $# > 0 )); do
  case "$1" in
    --base) BASE="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --head) HEAD="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --title) TITLE="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --body-file) BODY_FILE="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --reviewer) REVIEWER="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$BASE" || -z "$HEAD" || -z "$TITLE" || -z "$BODY_FILE" ]]; then
  echo "usage: create-pr.sh --base <branch> --head <branch> --title <title> --body-file <path> [--reviewer <login>]" >&2
  exit 2
fi

echo "==> Opening pull request: $HEAD -> $BASE"
gh pr create "${ARGS[@]}" --reviewer "$REVIEWER"

SYNC_PR_STATE="${SYNC_PR_STATE:-$HERE/sync-pr-state.sh}"
if [[ -x "$SYNC_PR_STATE" ]]; then
  echo "==> Correcting the board's PR State"
  if ! "$SYNC_PR_STATE"; then
    echo "note: the board was not corrected — run scripts/sync-pr-state.sh" >&2
  fi
fi
