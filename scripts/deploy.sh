#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Build the container images locally and ship them to the
# deployment VM.
#
# Why not build on the VM: the Always Free shape this project runs on
# (VM.Standard.E2.1.Micro) has 1GB RAM, which isn't enough to compile the
# Rust/wasm workspace. So this always builds locally (where there's room)
# and transfers the finished images instead of the source — `docker save`,
# scp, `docker load`, `docker compose up`. See docs/3.3-testing-ci-and-release.md's
# "Container Deployment" section for the full story, including the Oracle
# Cloud networking setup this assumes is already in place.
#
# What gets built is a *fresh checkout of a commit*, never the working
# tree. The build happens in a throwaway `git worktree`, so nothing on
# your disk — the branch you have checked out, staged changes, a
# half-finished edit — can reach production. Two things follow from that:
# deploying an older release is an ordinary operation rather than a
# manoeuvre (pass its ref), and "what is running in production" is always
# answerable from source control alone.
#
# Refuses to run unless: the commit is on origin/main, CI passed for it,
# the rehearsal host is currently running it, and production's database hasn't
# already moved past the schema this build knows. See the checks below.
#
# The deploy itself, once those pass:
#
#   1. build the images from a clean checkout, transfer them
#   2. retag the live images :previous, so rollback is a retag not a rebuild
#   3. stop the server and snapshot the database
#   4. apply migrations on their own — a failure here aborts with the
#      previous version still installed, rather than taking the site down
#   5. start the new version
#   6. smoke test the public URL for the expected version, and roll back
#      automatically if it doesn't appear
#
# Steps 3-6 are what make a bad release recoverable in seconds instead of a
# rebuild; `scripts/rollback.sh` does the same thing by hand.
#
# Usage:
#   ./scripts/deploy.sh                # deploy HEAD
#   ./scripts/deploy.sh <commit-ish>   # deploy a specific commit/tag/branch,
#                                      # e.g. `./scripts/deploy.sh prod-0.4.12`
#                                      # to roll back to a previous release
#
# Configure via environment variables (defaults match the current VM):
#   DEPLOY_ENV       production | rehearsal (default: production)
#   DEPLOY_HOST      Public IP or hostname of the VM (default: 129.151.69.246)
#   DEPLOY_USER      SSH user (default: ubuntu)
#   DEPLOY_SSH_KEY   Private key path (default: ~/.ssh/oracle_tile_lite_elite)
#   DEPLOY_REMOTE_DIR  Directory on the VM holding docker-compose.yml (default: tile-lite-elite)
#
# Everything defaults to production, so an unset environment behaves exactly
# as this script always has. `scripts/deploy-rehearsal.sh` sets the lot.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_ENV="${DEPLOY_ENV:-production}"
DEPLOY_HOST="${DEPLOY_HOST:-129.151.69.246}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
DEPLOY_SSH_KEY="${DEPLOY_SSH_KEY:-$HOME/.ssh/oracle_tile_lite_elite}"
DEPLOY_REMOTE_DIR="${DEPLOY_REMOTE_DIR:-tile-lite-elite}"
# Production is gated on both hosts, because they answer different questions.
#
# The rehearsal host answers "did the release mechanism work against a real
# host", which is a far stronger guarantee than "did you look at it on
# localhost" — and when it arrived it replaced the preview check on exactly
# that reasoning. That was half right. Stronger at proving the *deploy*, and
# no answer at all to the other question preview is for: did somebody use the
# change and find it does what was wanted. The two were one environment before
# they were split, which is how one check came to stand for both.
#
# STAGING_URL is still honoured so an existing environment or muscle-memory
# override keeps working.
REHEARSAL_URL="${REHEARSAL_URL:-${STAGING_URL:-https://129.151.84.183.sslip.io}}"
PREVIEW_URL="${PREVIEW_URL:-http://localhost:8081}"
# The URL of the host this script is acting on — production by default, the
# rehearsal host when a wrapper says so. Named TARGET_URL rather than
# PROD_URL because it is not always production: deploy-preview.sh and
# status.sh both use PROD_URL to mean the *live site*, and one name meaning
# both "my target" and "the live site" in scripts that run in the same
# session is how a value set for one silently changes the other (#24).
# Whether TARGET_URL came from the environment, recorded before defaulting —
# the guard below needs to tell "the caller set it" from "we defaulted it".
TARGET_URL_FROM_ENV="${TARGET_URL:+yes}"
TARGET_URL="${TARGET_URL:-https://tileliteelite.com}"
if [[ -n "${PROD_URL:-}" && -z "$TARGET_URL_FROM_ENV" ]]; then
  echo "error: PROD_URL is set but this script now reads TARGET_URL." >&2
  echo "       It was renamed because PROD_URL means the live site elsewhere;" >&2
  echo "       silently honouring it here would smoke-test the wrong host." >&2
  echo "       Set TARGET_URL=${PROD_URL} instead." >&2
  exit 1
fi
# How many pre-deploy database snapshots to keep on the VM. Rollback is
# expected to happen immediately if at all (a later rollback would discard
# real play), so depth beyond the last few releases has no consumer.
SNAPSHOT_KEEP="${SNAPSHOT_KEEP:-5}"

case "$DEPLOY_ENV" in
  production|rehearsal) ;;
  *) echo "error: DEPLOY_ENV must be 'production' or 'rehearsal', not '$DEPLOY_ENV'." >&2; exit 1 ;;
esac

# --- Emergency changes -------------------------------------------------------
#
# `DEPLOY_EMERGENCY="<why>"` — restore service when the normal path is too slow.
# See docs/3.3, "Emergency changes", which says the important part: **try
# rollback first.** `rollback.sh` is a retag and a restore, needs no build and
# no transfer, and has no gates because it only ever moves to something that
# was already running. This path is for when rolling back cannot help — a bug
# that has been live for a week, or an outage caused by something outside the
# image.
#
# It skips exactly two gates, and they are the two that cost time: standing
# this commit up on preview, and on rehearsal. Each is a full image build plus
# a transfer and a deploy.
#
# It does **not** skip CI. One complete run, e2e included, is the check worth
# waiting for — it is the only thing between here and production that has
# actually exercised the change. `DEPLOY_SKIP_CI` still exists and still means
# what it did: GitHub itself is unreachable. That is a different problem from
# production being down, and conflating them would let an emergency quietly
# ship something nothing had run.
#
# Nor does it skip the two that are not policy: the commit must be on a remote
# branch, or production runs something that exists only on this machine and
# there is nothing to roll back to or reason about afterwards; and the database
# must not have outrun the image, which is physics rather than process — that
# server would not boot, turning a bug into an outage.
EMERGENCY=""
if [[ -n "${DEPLOY_EMERGENCY:-}" ]]; then
  case "$DEPLOY_EMERGENCY" in
    1|true|yes) EMERGENCY="(no reason given at the time)" ;;
    *)          EMERGENCY="$DEPLOY_EMERGENCY" ;;
  esac
  echo
  echo "  ############################################################"
  echo "  ##  EMERGENCY DEPLOY                                      ##"
  echo "  ##  preview and rehearsal are being skipped.              ##"
  echo "  ##  CI still has to pass, e2e included.                   ##"
  echo "  ############################################################"
  echo "  reason: $EMERGENCY"
  echo
  echo "  Have you tried ./scripts/rollback.sh? It is seconds, not minutes,"
  echo "  and needs no build. Ctrl-C now if you have not."
  echo
fi

# What a *release* means only applies to production: the prod-* tag is the
# deployment log, the version bump moves the tree past what is now live, and
# the milestone closure records what reached users. A rehearsal does none of
# those things — it proves the mechanism. Tagging prod-0.4.19 for a deploy
# that never touched production would corrupt the one record that answers
# "what has actually shipped".
IS_RELEASE=0
[[ "$DEPLOY_ENV" == "production" ]] && IS_RELEASE=1

# `-n` redirects ssh's stdin from /dev/null. Without it ssh reads the
# script's own stdin, and a command run before an interactive prompt
# swallows the answer: rollback.sh's confirmation read hit EOF and
# `set -e` aborted it. Found during the 2026-08-01 rollback drill, on the
# most destructive command in the repo — the one place a prompt must work.
SSH_OPTS=(-n -i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
# The same connection options minus `-n`, which is an ssh-only flag: scp
# rejects it outright ("unknown option -- n") and the transfer dies after the
# images have already been built and compressed. Found by a real deploy —
# every check I had run stopped at the gates and never reached the scp.
SCP_OPTS=(-i "$DEPLOY_SSH_KEY" -o ConnectTimeout=10)
REMOTE="$DEPLOY_USER@$DEPLOY_HOST"

cd "$REPO_DIR"

# Which script is this? deploy.sh runs from the working tree, not from the
# commit being deployed — the payload is always a clean worktree checkout,
# but the *script* is whatever is on disk now. So a production deploy made
# while sitting on a feature branch runs that branch's tooling, silently.
# Printing the script's own identity makes that visible in the output
# instead of remembered. See issue #14 for why this is a mitigation rather
# than a fix (the fix is a separate released-scripts checkout, judged not
# worth its own upkeep).
SCRIPT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SCRIPT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
SCRIPT_DIRTY=""
git diff --quiet -- scripts/ 2>/dev/null || SCRIPT_DIRTY=" (uncommitted changes in scripts/)"
echo "==> $DEPLOY_ENV deploy, using tooling from $SCRIPT_BRANCH@$SCRIPT_SHA$SCRIPT_DIRTY"

# Production should only ever run merged tooling; unmerged tooling belongs on
# the rehearsal host, which is what it is for. Rehearsal deliberately has no
# such guard — a guard there would defeat the environment's purpose.
if (( IS_RELEASE )) && { [[ "$SCRIPT_BRANCH" != "main" ]] || [[ -n "$SCRIPT_DIRTY" ]]; }; then
  echo
  echo "    WARNING: deploying to production with tooling that is not merged."
  echo "    Test tooling changes on the rehearsal host first:"
  echo "        ./scripts/deploy-rehearsal.sh"
  echo
  # Gates-only changes nothing, so there is nothing here to protect production
  # from. Skipping the whole confirmation — the prompt as well as the refusal —
  # is also what lets the gate suite run at all: a test has no terminal.
  #
  # The prompt has to go with it, not just the refusal. Leaving `read` reachable
  # made a gates-only run hang instead of answering, which is the same trap the
  # paragraph below describes and was caught the same way: by running it.
  if [[ "${DEPLOY_GATES_ONLY:-}" == "1" ]]; then
    echo "    (gates only — nothing will be deployed, so not asking)"
  else
    # Refuse rather than block when there is no terminal. A bare `read` with
    # no stdin waits forever, so this hung a non-interactive run instead of
    # failing it — found by testing the guard itself. A deploy that hangs is
    # worse than one that stops, the same lesson as the `timeout 300` around
    # --migrate-only.
    if [[ ! -t 0 ]]; then
      echo "    Not a terminal, so this cannot be confirmed. Refusing." >&2
      echo "    Merge the tooling to main first, or run this interactively." >&2
      exit 1
    fi
    read -r -p "    Type 'production' to run this anyway: " CONFIRM_TOOLING
    if [[ "$CONFIRM_TOOLING" != "production" ]]; then
      echo "    Stopped — nothing was deployed."
      exit 1
    fi
  fi
fi

# Fail fast with a clear message rather than a confusing worktree error
# further down if the ref doesn't exist locally.
DEPLOY_REF="${1:-HEAD}"
if ! TARGET_FULL_SHA="$(git rev-parse --verify "${DEPLOY_REF}^{commit}" 2>/dev/null)"; then
  echo "error: '$DEPLOY_REF' is not a valid local git ref (fetch it first if it's remote-only)" >&2
  exit 1
fi
# `gh run list --commit` matches on the full hash only — a short one silently
# returns no runs, which would make the CI gate below fail every deploy.
TARGET_SHA="$(git rev-parse --short "$TARGET_FULL_SHA")"

# The working tree has no say in what ships, so a dirty one isn't an error
# here — it simply isn't part of the deploy. Say so rather than staying
# quiet: the previous behaviour (refusing to run until the tree was clean)
# taught the opposite expectation, that deploy.sh builds what you can see.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Note: your working tree has uncommitted changes. They are NOT part of"
  echo "    this deploy — $TARGET_SHA is built from a clean checkout of that commit."
fi

# Refuses to ship a commit that only exists on this machine — if this
# machine were lost before anyone/anything else had a copy, "what's
# actually running in production" would stop being reproducible from
# source control at all. Fetches first so a stale local view of the
# remote can't produce a false pass.
#
# Asks that question directly rather than through the current branch's
# upstream. The property that matters is "this commit is on the remote";
# a branch's tracking config is only ever a proxy for it, and the proxy
# rejected the case this script now exists to support — a commit reached
# by tag or SHA has no `@{u}` at all, so a rollback failed a gate it
# actually passed.
#
# Any remote branch, not `origin/main` specifically. The comment above is
# the rule — "this commit is on the remote" — and pinning it to main was
# stricter than that without saying so. It also blocked a legitimate case:
# deploying a branch deliberately, to trial a change or to rehearse a
# rollback with something you intend to abandon (docs/3.3's "Rollback
# drill"). A branch that has been pushed is just as reproducible as main;
# what must never ship is a commit that exists only on this machine.
#
# `grep -v '\->'` drops the `origin/HEAD -> origin/main` symbolic line,
# which is not a branch and would otherwise make any commit look reachable.
git fetch --quiet origin
REMOTE_BRANCHES="$(git branch -r --contains "$TARGET_FULL_SHA" 2>/dev/null | grep -v '\->' | tr -d ' ' | tr '\n' ' ' || true)"
if [[ -z "$REMOTE_BRANCHES" ]]; then
  echo "error: $TARGET_SHA ($DEPLOY_REF) is not on any remote branch — push it first." >&2
  echo "       Production must only ever run a commit that survives losing this machine." >&2
  exit 1
fi
echo "==> $TARGET_SHA confirmed on the remote ($REMOTE_BRANCHES)"

# Refuses to ship a commit CI hasn't passed. Until this existed, CI was
# only a signal running alongside the release rather than a gate on it: a
# red run stopped nothing, and the only real check was whoever remembered
# to run the suites by hand.
#
# Delegated to ci-status.sh so that the check made by hand at step 1.e and
# the one enforced here are the same code, and cannot answer differently.
#
# **Named run, not any run.** A production deploy ships what is on `main`, so
# the run that answers for it is the push to `main` — and `e2e` is required
# explicitly, because a job whose `if` does not match is recorded as `skipped`
# and a run of skipped jobs still concludes success. Asking the looser question
# is what passed the commit released as 0.5.0, whose only run that executed
# e2e had failed. See docs/3.3, "Gating on a particular run".
#
# **Which run depends on the environment.** A rehearsal exercises a commit that
# is usually still on a branch, so there is no push-to-`main` run to wait for —
# asking for one blocked the gate for its full twenty minutes and never reached
# the build. And e2e cannot be required of a branch push, because it does not
# run there: requiring it would refuse every rehearsal rather than every other
# one.
if (( IS_RELEASE )); then
  CI_RUN=(--run push:main --require e2e)
else
  CI_RUN=(--run push)
fi
if [[ "${DEPLOY_SKIP_CI:-}" == "1" ]]; then
  echo "==> WARNING: skipping the CI gate (DEPLOY_SKIP_CI=1)"
# `--wait` rather than a bare check: CI takes 3-10 minutes, so deploying
# shortly after a push otherwise refuses with "still in progress" and leaves
# you to run the wait by hand and come back. Blocking here folds that into
# the one command you already typed.
elif ! "$REPO_DIR/scripts/ci-status.sh" --wait \
  "${CI_RUN[@]}" "$TARGET_FULL_SHA"; then
  echo "error: refusing to deploy — see above. Fix CI rather than deploying past it," >&2
  echo "       or set DEPLOY_SKIP_CI=1 if GitHub itself is the problem." >&2
  exit 1
fi

# The pull request's own run, separately, because it is an independent answer.
# A version branch is merged fast-forward, so the released commit *is* the
# branch tip the PR tested — and for the commit released as 0.5.0 that run had
# failed, which this alone would have refused.
#
# Conditional, because not every change has a pull request: the merge lane
# routinely does not. Absence is therefore a pass, which is the shape that let
# 0.5.0 through, so it is **said out loud** rather than skipped quietly. A line
# reading "no pull-request run" is something you can notice and question; a
# gate that stays silent when it has nothing to check is not.
if (( ! IS_RELEASE )) || [[ "${DEPLOY_SKIP_CI:-}" == "1" ]]; then
  :
# The same query shape ci-status.sh uses, counted here in bash rather than by
# `gh --jq`. Two ways of asking the same question about the same data is how
# they come to disagree — and the count was the only place relying on gh's
# embedded jq, which made this branch the one part of the gate a test could not
# reproduce faithfully.
elif ! printf '%s\n' "$(gh run list --commit "$TARGET_FULL_SHA" --workflow CI --limit 30 \
      --json databaseId,event,headBranch,status,conclusion,url \
      --jq '.[] | [.databaseId, .event, .headBranch, .status, .conclusion, .url] | @tsv' \
      2>/dev/null || true)" | cut -f2 | grep -qx 'pull_request'; then
  echo "==> No pull-request run for this commit — nothing to check there"
elif ! "$REPO_DIR/scripts/ci-status.sh" --run pull_request "$TARGET_FULL_SHA"; then
  echo "error: refusing to deploy — the pull request for this commit did not pass CI." >&2
  echo "       That run is the one that exercises e2e against the branch." >&2
  exit 1
fi

# Ordered before the rehearsal check deliberately. This is an impossibility,
# not a process requirement: no amount of rehearsing makes an image bootable
# against a database it does not understand. Checked second, a rollback
# across a migration was told "rehearse it first", which costs four
# minutes of rebuilding before the deploy refuses anyway. Found in the
# 2026-08-01 rollback drill.
# Refuses to ship an image the live database has already moved past.
#
# Migrations only go forward. sqlx validates, on startup, that every
# migration recorded in the database is one the binary knows about
# (`ignore_missing` is false by default), so an older image meeting a
# newer database fails with `VersionMissing` and **never boots**. Without
# this check that failure arrives after the images are built, transferred
# and swapped in — i.e. as an outage.
#
# The database's own version comes from `/health`'s `schema_version`; the
# target's comes from the migration filenames in that commit's tree, read
# straight out of git so this can run before anything is checked out.
TARGET_SCHEMA="$(git ls-tree --name-only "$TARGET_FULL_SHA" crates/server-game/migrations/ \
  | grep '\.sql$' | sed 's#.*/##' | grep -oE '^[0-9]+' | sort -n | tail -1 | sed 's/^0*//')"
PROD_HEALTH="$(curl -sf --max-time 8 "$TARGET_URL/health" 2>/dev/null || true)"
LIVE_SCHEMA="$(printf '%s' "$PROD_HEALTH" | grep -o '"schema_version":[0-9]*' | cut -d: -f2 || true)"

if [[ -z "$PROD_HEALTH" ]]; then
  echo "==> Note: couldn't reach $TARGET_URL/health, so the schema check was skipped."
elif [[ -z "$LIVE_SCHEMA" ]]; then
  # Every deployment before this field existed. Nothing to compare against,
  # and saying so is better than silently passing a check that never ran.
  echo "==> Note: production reports no schema_version (it predates the field),"
  echo "    so the schema check was skipped. It applies from the next deploy on."
elif (( LIVE_SCHEMA > TARGET_SCHEMA )); then
  echo "error: production's database is at migration $LIVE_SCHEMA, but $TARGET_SHA only knows up to $TARGET_SCHEMA." >&2
  echo "       That image would fail sqlx's startup check and never boot." >&2
  echo "" >&2
  echo "       Migrations don't run backwards. To go back past one, restore the" >&2
  echo "       snapshot taken before the deploy that applied it:" >&2
  echo "         ./scripts/rollback.sh                  # list snapshots and images" >&2
  echo "         ./scripts/rollback.sh <snapshot>       # restore it, then deploy" >&2
  exit 1
else
  echo "==> Schema check passed (database at $LIVE_SCHEMA, $TARGET_SHA knows up to $TARGET_SCHEMA)"
fi

# Read from the deployed commit's own tree, not the working tree's
# Cargo.toml — on a rollback those are different numbers, and the tag has
# to name the version that actually shipped.
DEPLOYED_VERSION="$(git show "$TARGET_FULL_SHA:Cargo.toml" | grep -m1 '^version' | cut -d'"' -f2 || true)"
if [[ -z "$DEPLOYED_VERSION" ]]; then
  echo "error: couldn't read a version from $TARGET_SHA's Cargo.toml." >&2
  exit 1
fi

# A patch release may not carry functional change — the rule and the reasoning
# are in docs/3.3, "Releases are branches". Checked here, before anything is
# built, so a wrong version number costs a moment rather than a release. The
# check passes whenever it cannot judge (no milestone, no `gh`, no network), so
# it can only ever catch a mistake, never invent one.
if (( IS_RELEASE )); then
  "$REPO_DIR/scripts/check-release-version.sh" "$DEPLOYED_VERSION"
fi

# Refuses to ship a commit that was never actually exercised on the rehearsal host —
# a passing `cargo test` only proves the code compiles and unit-tests
# clean, not that it boots/migrates cleanly in a real container. Without
# this check, rehearsing commit A and then committing a "quick
# fix" B before deploying would silently ship B untested — easy to do
# without noticing, since deploy.sh has no other way to know the rehearsal host
# wasn't re-run. See docs/3.3-testing-ci-and-release.md.
if [[ "$DEPLOY_REF" == "HEAD" ]]; then
  STAGING_CMD="./scripts/deploy-rehearsal.sh"
else
  STAGING_CMD="./scripts/deploy-rehearsal.sh $DEPLOY_REF"
fi
# Gating a rehearsal on another environment is circular — the rehearsal is
# what the gate is *for*.
#
# The preview environment is deliberately *not* a gate. A gate can only
# check that the bits were present somewhere, never that you looked at them
# and were happy, so gating on preview adds friction while proving nothing
# the rehearsal does not already prove better.
if (( ! IS_RELEASE )); then
  echo "==> Skipping the rehearsal gate: this deploy is the rehearsal"
else
# The user-testing gate — and it is worth being honest about what it can do.
# It proves this commit was *deployed* to preview. It cannot prove anybody
# looked at it, and nothing else in the pipeline can either: whether a person
# formed a judgement is not observable from here. So this is a prompt, not a
# proof, and the only one available for the question.
#
# That is also the argument against having it. A technical change may be
# better tested elsewhere, and user testing could reasonably happen against a
# branch — which the process does not currently allow, since preview deploys
# HEAD. Both are reasons to skip it deliberately, not reasons to drop it:
# skipping is visible, and absence is not.
#
# Skippable, because some changes have nothing a person can look at — release
# tooling, most obviously, which is exactly the kind of change that cannot be
# rehearsed either. The variable says "there was nothing to see", not "I did
# not look", so it is named for the gate rather than for the inconvenience.
if [[ -n "$EMERGENCY" ]]; then
  echo "==> Skipping the preview gate (emergency)"
elif (( IS_RELEASE )) && [[ "${DEPLOY_SKIP_PREVIEW:-}" != "1" ]]; then
  PREVIEW_HEALTH="$(curl -sf --max-time 5 "$PREVIEW_URL/health" 2>/dev/null || true)"
  PREVIEW_VERSION="$(printf '%s' "$PREVIEW_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  PREVIEW_SHA="${PREVIEW_VERSION#*+}"
  if [[ -z "$PREVIEW_VERSION" ]]; then
    echo "error: preview ($PREVIEW_URL) isn't running — look at this commit there first:" >&2
    echo "           ./scripts/deploy-preview.sh" >&2
    echo "       DEPLOY_SKIP_PREVIEW=1 if there is nothing for a person to look at." >&2
    exit 1
  elif [[ "$PREVIEW_SHA" != "$TARGET_SHA" ]]; then
    echo "error: preview is running commit $PREVIEW_SHA, not $TARGET_SHA ($DEPLOY_REF)." >&2
    echo "       Look at this commit there first: ./scripts/deploy-preview.sh" >&2
    echo "       DEPLOY_SKIP_PREVIEW=1 if there is nothing for a person to look at." >&2
    exit 1
  fi
fi

if [[ -n "$EMERGENCY" ]]; then
  echo "==> Skipping the rehearsal gate (emergency)"
else
STAGING_HEALTH="$(curl -sf --max-time 5 "$REHEARSAL_URL/health" 2>/dev/null || true)"
# `|| true` on every one of these: `grep` exits 1 when it matches nothing,
# and under `set -o pipefail` that kills the assignment outright — so the
# "is it empty" branch written to handle exactly that case never runs, and
# the script dies with no message at all. This is not hypothetical; it
# aborted a production deploy silently.
STAGING_VERSION="$(printf '%s' "$STAGING_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
STAGING_SHA="${STAGING_VERSION#*+}"
if [[ -z "$STAGING_VERSION" ]]; then
  echo "error: the rehearsal host ($REHEARSAL_URL) isn't reachable — rehearse this commit first: $STAGING_CMD" >&2
  exit 1
elif [[ "$STAGING_SHA" == "$STAGING_VERSION" ]]; then
  echo "error: the rehearsal host is running $STAGING_VERSION, which has no commit id — was it deployed via deploy-rehearsal.sh?" >&2
  exit 1
elif [[ "$STAGING_SHA" != "$TARGET_SHA" ]]; then
  echo "error: the rehearsal host is running commit $STAGING_SHA, not $TARGET_SHA ($DEPLOY_REF) — rehearse it first: $STAGING_CMD" >&2
  exit 1
fi
echo "==> Rehearsal host confirmed running this commit ($TARGET_SHA) — proceeding"
fi
fi

# Every gate has now had its say, and nothing has been changed yet. That makes
# this the one point where the checks can be exercised without deploying —
# which is what `DEPLOY_GATES_ONLY=1` is for, and what makes
# `scripts/tests/deploy.test.sh` possible at all.
#
# Until it existed, these gates were only ever run by deploying, so the branch
# where each says **no** almost never ran: nobody rehearses a deploy against a
# commit they expect to be refused. Two gates had already failed open for
# exactly that reason, and a third (#100) refused every rehearsal for a day
# before a person tripped over it.
#
# Useful by hand too — "would this deploy be allowed?" is worth being able to
# ask without finding out the expensive way.
if [[ "${DEPLOY_GATES_ONLY:-}" == "1" ]]; then
  echo "==> Gates only: every check passed, stopping before anything is built"
  exit 0
fi

# The fresh checkout. A throwaway `git worktree` rather than checking $REF
# out here: it leaves the real working copy (branch, staged and unstaged
# changes) completely untouched, which is what makes it safe to deploy an
# older commit in the middle of unrelated work.
#
# The compose file comes from the worktree too, so the runtime
# configuration shipped to the VM is the one that belongs to the code
# being shipped — on a rollback, that matters as much as the images do.
WORKTREE_DIR="$(mktemp -d /tmp/tile-lite-elite-deploy-worktree-XXXXXX)"
TMP_TAR=""
cleanup() {
  # `if` rather than `[[ ... ]] &&`: an empty TMP_TAR would make the last
  # command in an EXIT trap return non-zero under `set -e`.
  if [[ -n "$TMP_TAR" ]]; then
    rm -f "$TMP_TAR"
  fi
  git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT
# rmdir first: `git worktree add` refuses to target a directory mktemp
# already created, even an empty one.
rmdir "$WORKTREE_DIR"
git worktree add --detach "$WORKTREE_DIR" "$TARGET_FULL_SHA" >/dev/null

# Baked into both binaries as SemVer build metadata (e.g. `0.2.0+a1c9f02`) —
# see docs/4.1-configuration.md's "Versioning" section.
export TILE_LITE_ELITE_BUILD_ID="$TARGET_SHA"

# `-f <worktree>/docker-compose.yml` also sets the project directory to the
# worktree, so each service's `context: .` resolves to the checkout rather
# than to this repo. The image tags are unaffected: they derive from the
# `name:` pinned inside the compose file, not from the directory.
echo "==> Building images from a clean checkout of $TARGET_SHA (the slow step, ~2-3 min)"
docker compose -f "$WORKTREE_DIR/docker-compose.yml" build

echo "==> Exporting images"
TMP_TAR="$(mktemp /tmp/tile-lite-elite-images-XXXXXX.tar.gz)"
docker save tile-lite-elite-server:latest tile-lite-elite-web:latest | gzip > "$TMP_TAR"
echo "    $(du -h "$TMP_TAR" | cut -f1) compressed"

echo "==> Transferring to $DEPLOY_HOST"
ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p $DEPLOY_REMOTE_DIR"
scp "${SCP_OPTS[@]}" "$TMP_TAR" "$WORKTREE_DIR/docker-compose.yml" "$REMOTE:$DEPLOY_REMOTE_DIR/"

REMOTE_TAR_NAME="$(basename "$TMP_TAR")"
SNAPSHOT_NAME="pre-$DEPLOYED_VERSION-$TARGET_SHA-$(date -u +%Y%m%dT%H%M%SZ).tgz"

# Rolls production back to the images and database it had a moment ago.
# Delegated to rollback.sh so the automatic recovery below and the one you
# would run by hand are the same code, and cannot drift apart. `--yes`
# because at these call sites the deploy has already failed and the
# confirmation prompt would only stand between a broken site and its fix.
roll_back() {
  echo "==> Rolling back to the pre-deploy state" >&2
  if "$REPO_DIR/scripts/rollback.sh" --yes "$SNAPSHOT_NAME"; then
    echo "==> Rolled back. Production is as it was before this deploy." >&2
  else
    echo "error: THE ROLLBACK ALSO FAILED. Production may be down." >&2
    echo "       Snapshot to restore by hand: $SNAPSHOT_NAME" >&2
    echo "       ssh in and check: docker compose logs --tail=50 server" >&2
  fi
}

echo "==> Loading images and snapshotting the database"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR

    # Retag the live images as :previous *before* loading the new ones.
    # Without this the old image becomes dangling the moment :latest moves,
    # and the prune below destroys it — which is why rolling back used to
    # mean a full local rebuild and re-transfer for an image that had been
    # sitting here minutes earlier. Two generations, ~300MB, on a disk
    # that is 13% used.
    docker image tag tile-lite-elite-server:latest tile-lite-elite-server:previous 2>/dev/null || true
    docker image tag tile-lite-elite-web:latest tile-lite-elite-web:previous 2>/dev/null || true

    gunzip -c $REMOTE_TAR_NAME | docker load
    rm -f $REMOTE_TAR_NAME
    mkdir -p snapshots

    # Stop the server before snapshotting. The database is SQLite in WAL
    # mode, so tarring it live can capture a torn state — a main file
    # without the WAL entry that completes it. The container is about to be
    # recreated anyway, so quiescing it here costs no extra downtime and
    # makes the snapshot trustworthy.
    docker compose stop server > /dev/null

    # Uses the app's own image purely because it is already present and is
    # debian-slim, so it has tar — no extra pull onto a 1GB VM. The volume
    # is mounted read-only; this only ever reads.
    docker run --rm \
        -v tile-lite-elite-data:/data:ro \
        -v \"\$PWD/snapshots\":/snapshots \
        --entrypoint tar \
        tile-lite-elite-server:latest \
        czf /snapshots/$SNAPSHOT_NAME -C /data .
    echo \"    snapshot: \$(du -h snapshots/$SNAPSHOT_NAME | cut -f1)\"
"

# Apply the schema change on its own, before the new build becomes the
# server. Migrations otherwise run as a side effect of startup, which fuses
# "does the schema change work" with "does the new version serve traffic" —
# and fused, a failing migration is an outage, because the old container has
# already been replaced and the new one just exits and restarts. Asked
# separately, the old code is still installed and the deploy simply stops.
#
# `compose run` rather than a bare `docker run` so this gets the service's
# real volume mount and environment, exactly as the server would.
#
# Wrapped in a timeout because the failure mode of an image that *doesn't*
# understand `--migrate-only` is not an error — the flag is ignored, the
# server starts normally, and it runs forever. Found the hard way against a
# image built before the flag existed: the command simply never
# returned. A deploy that hangs is worse than one that fails, so cap it.
echo "==> Applying migrations (separately, so a failure here is not an outage)"
if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    timeout 300 docker compose run --rm --no-deps server --migrate-only
"; then
  echo "error: migrations failed (or timed out) — this build's schema change does not apply" >&2
  echo "       to production's database, or the image ignored --migrate-only and hung." >&2
  echo "       Nothing was swapped in. SQLite wraps each migration in a transaction," >&2
  echo "       so the database is unchanged, and the previous version is still installed." >&2
  echo "       Restoring the snapshot and restarting it now, to be certain." >&2
  roll_back
  exit 1
fi

echo "==> Starting the new version"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    set -e
    cd $DEPLOY_REMOTE_DIR
    docker compose up -d

    # Prunes the image the *previous* deploy had tagged :previous, which
    # this deploy's retag just displaced. Keeps exactly two generations.
    docker image prune -f > /dev/null

    # \`ls -t\` is safe here: these names are generated by this script and
    # contain no whitespace.
    ls -1t snapshots/*.tgz 2>/dev/null | tail -n +$((SNAPSHOT_KEEP + 1)) | xargs -r rm -f
    echo \"    snapshots kept: \$(ls -1 snapshots/*.tgz | wc -l)\"
"

# The smoke test. End to end on purpose — public DNS, TLS, Caddy, and the
# server behind it — because that is the path a player takes, and each hop
# is something a deploy can break without the container itself looking
# unhealthy. Checking the version rather than just a 200 is what makes it a
# test of *this* deploy: a stale container still answering would otherwise
# pass.
EXPECTED_VERSION="$DEPLOYED_VERSION+$TARGET_SHA"
echo "==> Smoke testing $TARGET_URL (expecting $EXPECTED_VERSION)"
SMOKE_OK=0
for _ in $(seq 1 30); do
  LIVE_HEALTH="$(curl -sf --max-time 5 "$TARGET_URL/health" 2>/dev/null || true)"
  # Unreachable /health is the normal state for the first few seconds here,
  # so this must survive matching nothing rather than abort the retry loop.
  LIVE_APP="$(printf '%s' "$LIVE_HEALTH" | grep -o '"app_version":"[^"]*"' | cut -d'"' -f4 || true)"
  if [[ "$LIVE_APP" == "$EXPECTED_VERSION" ]]; then
    SMOKE_OK=1
    echo "    $LIVE_HEALTH"
    break
  fi
  sleep 2
done

if (( SMOKE_OK == 0 )); then
  echo "error: production did not come up healthy on $EXPECTED_VERSION within 60s." >&2
  echo "       last /health: ${LIVE_HEALTH:-<no response>}" >&2
  roll_back
  exit 1
fi

echo "==> Ensuring the 'sa' alias for tile-lite-elite-admin is set up and current on the VM"
ssh "${SSH_OPTS[@]}" "$REMOTE" "
    # Drop any existing 'alias sa=' line first, then re-append the current
    # definition. A stale line (e.g. an old deploy dir, or the pre-rename
    # admin binary name) used to survive because the previous logic only
    # appended when *no* 'alias sa=' line existed at all — so an out-of-date
    # value was never refreshed. Delete-then-append converges to exactly one
    # correct line whether the alias was absent, current, or stale.
    sed -i '/alias sa=/d' ~/.bashrc 2>/dev/null || true
    echo \"alias sa='docker compose -f ~/$DEPLOY_REMOTE_DIR/docker-compose.yml exec server tile-lite-elite-admin'\" >> ~/.bashrc \
        || echo \"    (warning: could not set up the 'sa' alias for tile-lite-elite-admin)\"
"

# Stamp the deployed commit in git history. A tag rather than a commit: it
# points at the *thing that shipped*, not at the bump that follows it, and
# it costs no history. `git tag --list 'prod-*'` is then the deployment log,
# `git describe --tags` on any commit says which release it came after, and
# `git log prod-0.4.12..prod-0.4.13` is exactly what a given deploy carried.
#
# Annotated (-a), so it records who deployed and when as a real object
# rather than a bare pointer. Named explicitly against the deployed SHA, so
# it lands correctly regardless of the bump below.
DEPLOY_TAG="prod-$DEPLOYED_VERSION"
if (( ! IS_RELEASE )); then
  # No tag, and DEPLOY_TAG is still referenced by the messages below, so it
  # keeps a readable value rather than being unset under `set -u`.
  DEPLOY_TAG="(none — $DEPLOY_ENV deploy, not a release)"
  echo "==> No prod-* tag: this was a $DEPLOY_ENV deploy, not a release"
elif git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/$DEPLOY_TAG" > /dev/null; then
  # Same version deployed twice — a redeploy, a rollback to a release that
  # already carries its tag, or a bump that didn't happen. Keep both rather
  # than moving the tag: a force-moved tag loses the record of the earlier
  # deploy, which is the one thing this exists to keep.
  DEPLOY_TAG="$DEPLOY_TAG-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Tag exists already; using $DEPLOY_TAG"
fi
if (( IS_RELEASE )); then
  git -C "$REPO_DIR" tag -a "$DEPLOY_TAG" "$TARGET_FULL_SHA" \
    -m "Deployed to production $(date -u +%Y-%m-%dT%H:%MZ) from $TARGET_SHA"
  git -C "$REPO_DIR" push --quiet origin "$DEPLOY_TAG"
  echo "==> Tagged $DEPLOY_TAG"
fi

# The working tree moves one patch ahead of what was just shipped, so no
# later commit is ever built carrying a version number already live. This
# used to be a step you had to remember (docs/3.3, an explicit final step) — but it is
# only ever correct immediately after a successful deploy, which is exactly
# here, and nowhere else.
#
# Only when rolling *forward*, though. After a rollback the branch tip is
# already ahead of what's now in production, and bumping it again would
# claim a release that never happened — the version to move on from is the
# newest one, not the one just redeployed.
CURRENT_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
BRANCH_TIP="$(git -C "$REPO_DIR" rev-parse HEAD)"
NEXT_VERSION="$(printf '%s' "$DEPLOYED_VERSION" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"

if (( ! IS_RELEASE )); then
  echo "==> No version bump: a $DEPLOY_ENV deploy does not consume a version"
elif [[ "${DEPLOY_SKIP_BUMP:-}" == "1" ]]; then
  echo "==> Skipping the version bump (DEPLOY_SKIP_BUMP=1) — production is on $DEPLOYED_VERSION"
elif [[ "$BRANCH_TIP" != "$TARGET_FULL_SHA" ]]; then
  echo "==> Deployed $DEPLOYED_VERSION from an earlier commit, so leaving the version alone."
  echo "    Your branch ($CURRENT_BRANCH) is already ahead of what's now in production."
elif [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "==> Detached HEAD, so leaving the version alone — nothing to bump onto."
elif ! git -C "$REPO_DIR" diff --quiet -- Cargo.toml Cargo.lock; then
  echo "==> Cargo.toml/Cargo.lock have uncommitted edits, so leaving the version alone." >&2
  echo "    Bump to $NEXT_VERSION by hand once they're committed." >&2
else
  echo "==> Bumping the working tree to $NEXT_VERSION (production now holds $DEPLOYED_VERSION)"
  sed -i "0,/^version = \"$DEPLOYED_VERSION\"/s//version = \"$NEXT_VERSION\"/" "$REPO_DIR/Cargo.toml"
  # Refreshes Cargo.lock's workspace versions so the bump commit is complete.
  ( cd "$REPO_DIR" && cargo check --workspace --quiet > /dev/null 2>&1 || true )
  git -C "$REPO_DIR" add Cargo.toml Cargo.lock
  # Read API_VERSION from the commit, not the working tree. This commit
  # carries only Cargo.toml/Cargo.lock, so its api/src/lib.rs is HEAD's —
  # and check-commit-stamp.sh validates the stamp against the commit's own
  # tree. An uncommitted edit to API_VERSION would otherwise produce a
  # stamp that fails its own check.
  # One parser, shared with check-commit-stamp.sh and tested in
  # scripts/tests/ — rustfmt wraps this declaration once the numbers grow,
  # and both readers assumed one line. It exits non-zero rather than
  # printing nothing, so a version that cannot be read stops the bump
  # instead of writing a stamp its own checker would reject.
  BUMP_API="$(git -C "$REPO_DIR" show HEAD:crates/api/src/lib.rs \
    | "$(dirname "$0")/read-api-version.sh")"
  git -C "$REPO_DIR" commit --quiet \
    -m "app $NEXT_VERSION api $BUMP_API: bump dev version following production release" \
    -m "Production now runs $DEPLOYED_VERSION+$TARGET_SHA."
  git -C "$REPO_DIR" push --quiet origin "$CURRENT_BRANCH"
  echo "    committed and pushed"
fi

# Closes the milestone this release delivered, and opens the next one.
#
# GitHub's `Closes #N` fires when a commit reaches the default branch, which
# — with no branching here — is the moment it is *written*, not the moment
# it ships. That marked issues done while they sat unreleased, which is
# exactly what "track a change through to production" needs to distinguish.
# So commits say `Refs #N`, issue state means "work done", and the milestone
# means "in production". This is the step that makes the second one true.
#
# Rolling forward only, same test as the version bump: a rollback deploys an
# older version whose milestone closed long ago.
#
# Best-effort throughout. A GitHub hiccup must not fail a deploy that has
# already succeeded — production is live either way, and the worst case is a
# milestone closed by hand.
if (( ! IS_RELEASE )); then
  echo "==> No milestone change: a $DEPLOY_ENV deploy has not reached users"
elif [[ -n "$EMERGENCY" ]]; then
  # The tag and the version bump still happen above: those are facts about what
  # is running, and letting production and the repo disagree would be worse
  # than the emergency. Closing a milestone is a different kind of statement —
  # that a scope completed the normal process — which is precisely what did not
  # happen. The retrospective issue below carries the record instead, and
  # whoever reviews it closes what actually shipped.
  echo "==> No milestone change: an emergency deploy has not been through the normal process"
  MILESTONE="$(gh api "repos/{owner}/{repo}/milestones?state=open" \
    --jq ".[] | select(.title == \"$DEPLOYED_VERSION\") | .number" 2>/dev/null || true)"
  if [[ -n "$MILESTONE" ]]; then
    echo "==> Closing milestone $DEPLOYED_VERSION and its issues"
    for ISSUE in $(gh issue list --milestone "$DEPLOYED_VERSION" --state open \
      --json number --jq '.[].number' 2>/dev/null || true); do
      # `--reason completed` explicitly. It is the default, so nothing changes
      # today — but `stateReason` is how a closure's *reason* is recorded now
      # that the wontfix/invalid/duplicate labels are gone, and this is the one
      # site that closes an issue with no human present. A field that carries
      # meaning should not be left implicit exactly where nobody is watching.
      if gh issue close "$ISSUE" --reason completed \
        --comment "Released in $DEPLOY_TAG — production is running $DEPLOYED_VERSION+$TARGET_SHA." \
        > /dev/null 2>&1; then
        echo "    closed #$ISSUE"
      else
        echo "    warning: could not close #$ISSUE" >&2
      fi
    done
    gh api --method PATCH "repos/{owner}/{repo}/milestones/$MILESTONE" \
      -f state=closed > /dev/null 2>&1 \
      && echo "    milestone $DEPLOYED_VERSION closed" \
      || echo "    warning: could not close milestone $DEPLOYED_VERSION" >&2
  fi

  # The tree has just moved to NEXT_VERSION, so anything reported from here
  # belongs to that release. Creating it now means an issue never has to
  # wait for a milestone to exist before it can be filed.
  if [[ "${DEPLOY_SKIP_BUMP:-}" != "1" ]] \
    && ! gh api "repos/{owner}/{repo}/milestones?state=all" \
      --jq '.[].title' 2>/dev/null | grep -qx "$NEXT_VERSION"; then
    gh api repos/{owner}/{repo}/milestones -f title="$NEXT_VERSION" \
      -f description="Changes on main not yet in production." > /dev/null 2>&1 \
      && echo "    opened milestone $NEXT_VERSION for what comes next"
  fi
fi

# An emergency change is retrospectively reviewed, not unreviewed. The issue is
# raised here rather than printed as a command to run later, because a reminder
# issued at the worst moment of the week is a reminder that does not happen —
# and without the review the emergency path quietly becomes the normal one.
if [[ -n "$EMERGENCY" ]] && (( IS_RELEASE )); then
  echo
  echo "==> Emergency deploy — gates bypassed:"
  echo "        preview      this commit was never stood up for anyone to look at"
  echo "        rehearsal    the release mechanism was not exercised first"
  echo "    Everything else was checked, CI included."
  if command -v gh > /dev/null; then
    EMERGENCY_BODY="$(cat <<BODY
Production was deployed outside the normal path.

| | |
| --- | --- |
| version | \`$DEPLOYED_VERSION+$TARGET_SHA\` |
| tag | \`$DEPLOY_TAG\` |
| when | $(date -u '+%Y-%m-%d %H:%M UTC') |
| reason given | $EMERGENCY |

**Bypassed:** the preview gate, so nobody looked at this commit standing up;
and the rehearsal gate, so the release mechanism was not exercised against it
before production was.

**Not bypassed:** CI including e2e, the commit being on a remote branch, the
schema check, and the version checks.

The milestone was deliberately not closed — that would claim a scope completed
the normal process. Close what actually shipped by hand.

## To do

- [ ] Confirm production is behaving, beyond the deploy's own smoke test
- [ ] Say what the underlying problem was, separately from the fix — restoring
      service and understanding the cause are different questions
- [ ] Raise the normal change that makes this unnecessary next time
- [ ] Close the milestone and issues this release actually delivered
- [ ] Triage this issue: it has no type or lane yet, deliberately, because
      what it turns into is a judgement

Raised automatically by \`deploy.sh\`.
BODY
)"
    if gh issue create --title "Emergency deploy of $DEPLOYED_VERSION — review what was bypassed" \
      --body "$EMERGENCY_BODY" > /dev/null 2>&1; then
      echo "    raised a retrospective issue — review it before this is forgotten"
    else
      echo "    warning: could not raise the retrospective issue — raise one by hand" >&2
    fi
  fi
  echo
fi

echo "==> Done — https://$DEPLOY_HOST.sslip.io (or your configured hostname)"
