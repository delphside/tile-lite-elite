#!/usr/bin/env bash
set -uo pipefail

# verify.sh — one command that confirms everything is in place.
#
# `status.sh` *shows* you the world; this one *asserts* it, and exits non-zero
# if any of it is wrong. The difference matters: a display has to be read and
# interpreted, and the failure mode of reading is not noticing.
#
# It exists because CI and the deploy gates each answer at a moment you are not
# necessarily present for. CI answers after a push and only if you go and look;
# the deploy gates answer during a deploy, which is a bad time to discover the
# tooling is broken. Owner, 2026-08-15:
#
#   > Having CI run things is good to do, but we sometimes miss what CI does.
#   > We also need a command we type which confirms everything is in place.
#
# Read-only. It builds nothing, deploys nothing and changes nothing.
#
# ## Two orders, on purpose
#
# Checks **run** fastest-first, so a failure shows up in seconds rather than
# after the slow ones. Measured 2026-08-15: the deploy gate tests were 47s and
# the deploy gates 16s; everything else together is under two seconds.
#
# They are **summarised** in the order a release actually follows, which is the
# order that answers "how far would this get?".
#
# ## Why it does not stop at the first failure
#
# These are independent assertions about current state, not stages of a
# pipeline: a failing CI query says nothing about whether preview is reachable.
# Stopping would hide failures that are equally true, and mean fixing one,
# waiting, and finding the next. Running everything costs the tail of the slow
# checks and answers the whole question in one pass.
#
# ## Nothing is skipped quietly
#
# A check that cannot run says so and counts as a failure, because an absent
# answer must never read like a passing one. That is the failure this repository
# has hit most often, and the verdict line carries it too — a `--quick` run says
# what it did not do.
#
# ## `note` is not a failure
#
# One verdict reports rather than asserts: housekeeping that is worth seeing and
# blocks nothing. It never changes the exit status, so a non-zero exit keeps
# meaning "something is wrong" rather than "something is worth a look".

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

HERE="$(cd "$(dirname "$0")/.." && pwd)"

cd "$HERE"

declare -A RESULT DETAIL LABEL
failures=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
amber() { printf '\033[33m%s\033[0m' "$1"; }

# Records a verdict and prints it as it lands.
#
# `note` is not a fourth kind of failure. It reports something worth being aware
# of that is nobody's fault and blocks nothing — housekeeping, not correctness —
# so it must not colour the exit status, or the exit status stops meaning
# "something is wrong". Owner, 2026-08-17, on merged branches left behind:
# "Being notified is enough. It is good to be aware it is happening."
pass() { RESULT[$1]=ok;      DETAIL[$1]="${3:-}"; printf '  %s   %s\n' "$(green ok)" "$2"; }
fail() { RESULT[$1]=FAIL;    DETAIL[$1]="${3:-}"; failures=$((failures + 1)); printf '  %s %s\n' "$(red FAIL)" "$2"; }
skip() { RESULT[$1]=skipped; DETAIL[$1]="${3:-}"; printf '  %s %s\n' "$(amber '--')" "$2"; }
note() { RESULT[$1]=note;    DETAIL[$1]="${3:-}"; printf '  %s %s\n' "$(amber 'note')" "$2"; }

# ---------------------------------------------------------------------------
# The checks. Each sets its own verdict; none depends on another having run.
# ---------------------------------------------------------------------------

LABEL[tree]="Working tree clean"
check_tree() {
  if [[ -z "$(git status --porcelain)" ]]; then
    pass tree "working tree clean"
  else
    fail tree "working tree has uncommitted changes" "$(git status --porcelain | head -5)"
  fi
}

LABEL[pushed]="Branch pushed"
check_pushed() {
  # `--prune` is load-bearing for `check_branches`, which runs straight after
  # this and is the only thing that fetches. It reports a merged branch whose
  # remote is gone, and reads "gone" from `upstream:track` — which git only
  # sets once the stale remote-tracking ref has been pruned. Without it the ref
  # survives, `track` stays empty, and the check passes for a reason that has
  # nothing to do with branches.
  #
  # It did exactly that: `103-tab-icon` was merged on 2026-09-05, GitHub deleted
  # the remote on merge, and `verify.sh` reported "no merged branches left
  # behind" for a day. The check's own comment names `git fetch --prune` as the
  # mechanism it depends on, and nothing performed it.
  git fetch -q --prune origin 2>/dev/null || true
  local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$branch" 2>/dev/null)" ]]; then
    pass pushed "$branch matches origin"
  else
    local ahead; ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo '?')"
    fail pushed "$branch is $ahead commit(s) ahead of origin"
  fi
}

LABEL[ci]="CI passed for HEAD"
check_ci() {
  if ! command -v gh > /dev/null; then
    fail ci "CI not asked — no 'gh' on PATH"; return
  fi
  local out
  # Deliberately without --wait. A verification that blocks for twenty minutes
  # is not one anybody types.
  if out="$(./scripts/ci-status.sh --run "push:$(git rev-parse --abbrev-ref HEAD)" \
        "$(git rev-parse HEAD)" 2>&1)"; then
    pass ci "push run passed for $(git rev-parse --short HEAD)"
  else
    fail ci "push run has not passed for HEAD" "$(printf '%s' "$out" | tail -3)"
  fi
}

LABEL[branches]="No merged branches left behind"
check_branches() {
  # 3.3's "Delete the branch once its change is live" is a two-part step, and
  # only the first part can be automated away: GitHub can delete the *remote*
  # branch on merge, but nothing reaches this workstation to remove the local
  # one. `git fetch --prune` drops the remote-tracking ref and leaves the branch
  # — which is exactly how issue-33 and issue-50 survived their own releases
  # until 2026-08-17.
  #
  # Deliberately conservative: upstream gone *and* merged into origin/main. A
  # branch that never had an upstream might be a scratch branch mid-thought, and
  # naming it would train the reader to ignore this line.
  if ! git rev-parse --verify -q origin/main > /dev/null; then
    fail branches "cannot tell — no origin/main to compare against"; return
  fi
  local lines="" names="" ref track
  while read -r ref track; do
    [[ "$track" == "[gone]" ]] || continue
    git merge-base --is-ancestor "$ref" origin/main 2> /dev/null || continue
    names="$names $ref"
    lines+="$(printf '%s  (merged, remote deleted)' "$ref")"$'\n'
  done < <(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads)
  if [[ -z "$names" ]]; then
    pass branches "no merged branches left behind"
  else
    lines+="delete with: git branch -d$names"$'\n'
    note branches "merged branches still here:$names" "$lines"
  fi
}

LABEL[envs]="Environments reachable"
check_envs() {
  local lines="" bad=0 v
  for pair in "production https://tileliteelite.com" \
              "rehearsal https://rehearsal.tileliteelite.com" \
              "preview http://localhost:8081"; do
    set -- $pair
    v="$(curl -fsS --max-time 10 "$2/health" 2>/dev/null \
         | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p')"
    if [[ -n "$v" ]]; then
      lines+="$(printf '%-11s %s' "$1" "$v")"$'\n'
    else
      lines+="$(printf '%-11s unreachable' "$1")"$'\n'; bad=1
    fi
  done
  if (( bad )); then fail envs "an environment is unreachable" "$lines"
  else pass envs "production, rehearsal and preview all answering" "$lines"; fi
}

LABEL[unreleased]="What main holds that production does not"
# --- image changes waiting on main ------------------------------------- #387 R2
#
# Since D55 `main` is the accumulating next release, so tested-but-unshipped
# image changes sitting there is the expected state rather than a fault. What
# was missing is anybody being able to see them.
#
# **It matters most at the worst moment.** An emergency release cut from `main`
# ships everything here alongside the fix, and the person restoring service is
# in no position to audit it. `docs/3.3` says to cut from the last released tag
# instead; this is what makes the thing that rule protects against visible.
#
# **Counted in image terms, never in commits.** "3 commits ahead" is the answer
# to a different question -- documents and scripts reach `main` constantly and
# reach production never. `shipping-paths.sh` already decides what reaches the
# image, for the pre-commit hook and for the deploy manifest, and this is its
# third consumer rather than a second opinion.
check_unreleased() {
  local prod sha line="" n=0
  prod="$(curl -fsS --max-time 10 https://tileliteelite.com/health 2>/dev/null \
          | sed -n 's/.*"app_version":"[^+]*+\([^"]*\)".*/\1/p')"
  if [[ -z "$prod" ]]; then
    note unreleased "production did not answer, so nothing can be compared"; return
  fi
  if ! git cat-file -e "$prod^{commit}" 2>/dev/null; then
    note unreleased "production reports $prod, which is not a commit here" \
      "fetch, or production is running something this checkout does not have"
    return
  fi
  # **What ships, not what touches the image** (#421): after a release `main`
  # holds the next version's bump, which reaches the image by path and ships
  # nothing. The rule is `board/shipping.py`'s `ships`.
  while read -r sha; do
    [[ -n "$sha" ]] || continue
    if python3 "$(dirname "${BASH_SOURCE[0]}")/board-shipping.py" ships "$sha" </dev/null 2>/dev/null; then
      n=$((n + 1))
      line+="$(git log -1 --format='%h %s' "$sha" | cut -c1-96)"$'\n'
    fi
  done < <(git log --format=%H "$prod..origin/main" 2>/dev/null)
  UNRELEASED_SHIPPING="$n"
  if (( n == 0 )); then
    pass unreleased "production is level with main on everything that ships"
  else
    note unreleased "$n image change(s) on main and not in production" \
      "an emergency release cut from main would ship these too — cut from the last released tag"$'\n'"$line"
  fi
}

LABEL[rehearsal]="Rehearsal is closed"
# Rehearsal's gate (#240) is closed by *default*: with no `REHEARSAL_ACCESS_KEY` in the
# host's .env, docker-compose.yml supplies a sentinel and the Caddyfile compares
# every cookie against a value nobody holds, so the site refuses everybody. That
# is the safe failure, and it is also a silent one — a refusal looks the same
# whether the key is missing or simply not held by this machine.
#
# So the state is asserted here rather than discovered when somebody cannot get
# in. The probe needs no ssh and no extra configuration: the unlock path is
# `/unlock/{$REHEARSAL_ACCESS_KEY}`, so asking for the *sentinel's* unlock path answers
# 200 if and only if the host is running the sentinel, and 403 once a real key
# is set. Measured both ways, 2026-08-30.
#
# It sets the sentinel's cookie on the way past, which is why this is a curl and
# not a browser: nothing keeps it.
check_rehearsal() {
  local url="https://rehearsal.tileliteelite.com" body code
  body="$(curl -s -w '\n%{http_code}' --max-time 10 \
    "$url/unlock/no-rehearsal-key-configured" 2>/dev/null)" || body=$'\n000'
  code="${body##*$'\n'}"
  case "$code" in
    403)
      pass rehearsal "a key is configured and the gate is holding" ;;
    200)
      # 200 means two opposite things, and only the body tells them apart.
      # The sentinel's unlock handler answers with its own sentence; anything
      # else at this path is the SPA fallback, which means the gate is not in
      # the deployment at all. Found by running this against the live host
      # while the gate was still unmerged — it reported "locked" about a site
      # that was wide open.
      if [[ "$body" == *"Rehearsal unlocked"* ]]; then
        fail rehearsal "rehearsal has no access key — it is locked to everybody" \
          "fix with: ./scripts/rehearsal-access.sh grant"
      else
        fail rehearsal "rehearsal has no access gate — it is OPEN to the internet" \
          "the gate (#240) is not in the deployed image; deploy it"
      fi ;;
    000)
      fail rehearsal "rehearsal did not answer" \
        "the host may be down; the environments check above says which" ;;
    *)
      fail rehearsal "unexpected answer from rehearsal's gate: HTTP $code" ;;
  esac
}

LABEL[tests]="Tooling tests pass"
# **The runners, not a file pattern** (docs/3.3 §2.2). This looped over
# `scripts/tests/*.test.sh` and skipped any it could not find, so as the suites
# moved to bats on 2026-09-27 each batch dropped out of this check unnoticed,
# and with the last one gone it would have passed having run nothing. bats
# missing is a failure, not a skip, for the same reason.
check_tests() {
  if (( QUICK )); then skip tests "tooling tests skipped (--quick)"; return; fi
  if ! command -v bats >/dev/null 2>&1; then
    fail tests "bats is not installed, so the shell tooling's tests cannot run" \
      "sudo apt-get install -y bats bats-support bats-assert (setup-dev-environment.sh does this)"
    return
  fi
  local bad="" lines="" out
  # Named before it runs: the shell suites take about a minute, and an
  # unattributed silence reads as a hang. Only on a terminal.
  [[ -t 1 ]] && printf '       bats scripts/tests ... '
  if out="$(bats scripts/tests 2>&1)"; then
    [[ -t 1 ]] && printf '\r'
    printf '       %s %s\n' "$(green ok)" "bats: $(grep -c '^ok ' <<< "$out") tests          "
  else
    [[ -t 1 ]] && printf '\r'
    printf '       %s %s\n' "$(red FAIL)" "bats                     "
    bad="$bad bats"; lines+="$(grep '^not ok' <<< "$out" | head -5)"$'\n'
  fi
  if out="$(python3 -m unittest discover -s scripts -t scripts 2>&1)"; then
    printf '       %s %s\n' "$(green ok)" "unittest: $(sed -n 's/^Ran \([0-9]*\) tests.*/\1/p' <<< "$out") tests"
  else
    printf '       %s %s\n' "$(red FAIL)" "unittest"
    bad="$bad unittest"; lines+="$(grep -E '^(FAIL|ERROR):' <<< "$out" | head -5)"$'\n'
  fi
  if [[ -n "$bad" ]]; then fail tests "failing:$bad" "$lines"
  else pass tests "the shell and Python tooling tests pass"; fi
}

LABEL[gates]="A production deploy would be allowed"
check_gates() {
  if (( QUICK )); then skip gates "deploy gates skipped (--quick)"; return; fi
  # **Nothing to judge when nothing ships** (#421). Straight after a release
  # `HEAD` is the next version's bump, which preview and rehearsal never hold,
  # so asking whether it could deploy failed after every release by
  # construction, on the check whose exit status the lap says to trust.
  # `check_unreleased` runs first and says whether anything on main ships.
  if [[ "${UNRELEASED_SHIPPING:-}" == "0" ]]; then
    pass gates "nothing on main ships beyond production, so there is no deploy to judge"
    return
  fi
  local out status=0
  # Bounded. deploy.sh's CI gate polls with --wait, which is right for a deploy
  # and wrong here — it once made this sit for ten minutes against a run that
  # was still going.
  out="$(timeout 120 env DEPLOY_GATES_ONLY=1 ./scripts/deploy.sh 2>&1)" || status=$?
  if (( status == 124 )); then
    fail gates "gate check timed out after 120s (CI probably still running)"
  elif (( status == 0 )); then
    pass gates "a production deploy of HEAD would be allowed" \
      "$(printf '%s' "$out" | grep -E '^==> Gates run:')"
  else
    fail gates "a production deploy of HEAD would be refused" \
      "$(printf '%s' "$out" | grep -E '^error:' | tail -3)"
  fi
}

LABEL[token]="The machine account's token is not about to expire"
# **#309's cheaper half.** The token `gh` uses expires on a date, nothing warns,
# and the first symptom is a command failing in the middle of something else —
# pull requests, field mutations, milestones, every `gh`-calling script. Not
# `git push`, which is SSH, and not CI, which uses Actions' own token.
#
# The named failure is #308, the same class one cause along: an enrolment
# deadline nobody was tracking. This token was then found **by accident** while
# verifying that one, which is the argument for reading it rather than
# remembering it.
#
# GitHub returns the expiry as a header on any authenticated response, so this
# costs one call and no new credential.
#
# **Thirty days**, because rotating is the owner's and needs a sitting. Under
# seven it stops being a note: a week is little enough that the first symptom
# could arrive before the next look at this.
check_token() {
  local days
  # **Asks the model rather than the header.** `board/sources.py` already reads
  # `Github-Authentication-Token-Expiration` -- for R1, which prints the
  # countdown -- and this was written on 2026-09-21 reading it a second time,
  # hours after the argument for not doing that. One place, one answer.
  days="$(timeout 40 python3 -c '
import sys
sys.path.insert(0, "'"$(dirname "${BASH_SOURCE[0]}")"'")
from board.sources import token_days_left
left = token_days_left()
print("" if left is None else left)
' 2>/dev/null || true)"
  if [[ -z "$days" ]]; then
    # No expiry advertised: a credential that does not expire, or ssh. Nothing
    # to warn about, and silence is the right answer.
    pass token "no expiry is advertised for this credential"
  elif (( days < 7 )); then
    fail token "the token expires in $days day(s)"
  elif (( days < 30 )); then
    note token "the token expires in $days day(s)" \
      "regenerate at Settings -> Developer settings -> Fine-grained tokens, then gh auth login --with-token (#309)"
  else
    pass token "expires in $days days"
  fi
}

LABEL[hosts]="Rehearsal and production agree, and neither waits to reboot"
# **The trigger for #360 R4's cadence.** The owner chose "when reboot-required
# appears" over a calendar, which only works if something says when it appears.
# `check-hosts.sh` reads it; this is what makes somebody see it, attached to a
# command already run before a deploy rather than to a reminder.
#
# The named failure: production ran nine kernel revisions behind what it had
# installed, for weeks, and nothing reported it — measured 2026-09-19.
#
# A note, never a failure. A pending reboot is not a reason to refuse a deploy;
# it is a reason to schedule one, and that is the owner's call.
check_hosts() {
  local out
  if out="$(timeout 90 "$(dirname "${BASH_SOURCE[0]}")/check-hosts.sh" 2>&1)"; then
    pass hosts "same kernel, same Docker, neither waiting to reboot"
  else
    case "$out" in
      *"could not read"*) note hosts "a host could not be read" "$out" ;;
      *) note hosts "the hosts differ, or one is waiting to reboot" "$out" ;;
    esac
  fi
}

LABEL[prstate]="The board agrees with GitHub about pull requests"
# The `PR State` field is derived and never typed, so the only way it goes wrong
# is nobody running the thing that derives it — and nothing did. Found
# 2026-09-17 by the owner: **#386 and #390 both sat with no state at all**, one
# of them merged. A generated field with no generator on any path is a field
# that is right only by luck.
#
# **It corrects rather than reports**, which is the difference between a derived
# field and a judgement. `PR State` is computed from what GitHub already knows,
# so there is nothing for anybody to disagree with: reporting the drift meant a
# check, a glance, and then a command, for a value only one answer was ever
# right for. `document-map.py --write` has the same shape for the same reason.
#
# Twice on 2026-09-21 the field was found stale in the owner's own view — #386,
# #390, #391, #392 and #393 between them — each time because nothing had run the
# thing that derives it.
#
# It still says what it changed. A silent correction is how a field starts being
# wrong in a way nobody can see.
check_prstate() {
  local out
  if ! command -v gh >/dev/null 2>&1; then
    fail prstate "not checked — no 'gh' on PATH"; return
  fi
  if ! out="$(timeout 90 "$(dirname "${BASH_SOURCE[0]}")/board-pr-state.py" 2>&1)"; then
    fail prstate "could not reach the board to correct it" "$out"
    return
  fi
  # The script prints one line per correction and a summary; a clean run
  # corrects nothing, which is the ordinary case.
  local corrected
  corrected="$(sed -n 's/.*: \([0-9]*\) added, \([0-9]*\) corrected/\1 \2/p' <<< "$out")"
  if [[ "$corrected" == "0 0" ]]; then
    pass prstate "every pull request's state matches GitHub"
  else
    note prstate "corrected the board to match GitHub" "$out"
  fi
}

LABEL[transitions]="Issues have done the work their fields claim"
# Owner, 2026-09-05: run the transition check from here. It is
# board-check.py (R4) since 2026-09-19; check-transitions.sh is retired.
#
# **A note, never a failure**, and the reason is in the other script's own
# header: *"It reports; it does not refuse. A field is changed in a browser and
# nothing here can stand in front of that."* Making verify.sh exit non-zero for
# a project at Development with no test would put the deploy path's
# trusted status at the mercy of bookkeeping — and a status that goes red for
# something nobody can act on today is one people stop reading. Notes are
# counted for the verdict line and never for the exit status, which is exactly
# what this wants.
#
# Exit 2 is its own "no gh or jq" and is not a finding, so it is reported as
# not having run rather than as nothing being wrong. Absence must not read as a
# pass — the same rule the deploy's pull-request gate follows by saying "no
# pull-request run" out loud.
check_transitions() {
  local out status=0
  out="$(timeout 120 ./scripts/board-check.py --exit-code --no-colour 2>&1)" || status=$?
  if (( status == 124 )); then
    note transitions "the transition check timed out after 60s"
  elif (( status == 0 )); then
    pass transitions "every open issue has done the work its field claims"
  elif (( status == 2 )); then
    note transitions "the transition check could not run" \
      "$(printf '%s' "$out" | tail -2)"
  else
    # Both shapes board-check.py prints: `#N ...` for an issue against its
    # own obligations, and `  !! ...` for the sections that ask a question
    # about the release rather than about one issue -- the milestone's unbuilt
    # work, the tests it promised, a project it overtook. Matching only the
    # first meant those sections could turn this line red while saying nothing
    # about why, which for the milestone check is the whole content: it is the
    # pre-flight for a gate that will otherwise refuse the deploy.
    note transitions "some issues are further along than their content supports" \
      "$(printf '%s' "$out" | grep -E '^(#[0-9]|  !!)' | head -8)"
  fi
}

# ---------------------------------------------------------------------------
# Run fastest-first. Summarise in the order a release follows.
# ---------------------------------------------------------------------------

# `branches` runs straight after `pushed`, which is what does the fetch — it
# compares against origin/main and would otherwise read a stale one. In process
# order it comes last: tidying up after a change has shipped is the final step,
# and it is the only line here that is housekeeping rather than readiness.
RUN_ORDER=(tree pushed branches token envs unreleased hosts rehearsal transitions prstate ci tests gates)
PROCESS_ORDER=(tree pushed ci tests token envs unreleased hosts rehearsal transitions prstate gates branches)

printf '\n\033[1mChecking\033[0m  (fastest first, so a failure shows early)\n'
for key in "${RUN_ORDER[@]}"; do "check_$key"; done

printf '\n\033[1mIn process order\033[0m\n'
for key in "${PROCESS_ORDER[@]}"; do
  case "${RESULT[$key]:-notrun}" in
    ok)      printf '  %s   %s\n' "$(green ok)"     "${LABEL[$key]}" ;;
    FAIL)    printf '  %s %s\n'   "$(red FAIL)"     "${LABEL[$key]}" ;;
    note)    printf '  %s %s\n'   "$(amber 'note')" "${LABEL[$key]}" ;;
    skipped) printf '  %s %s\n'   "$(amber '--')"   "${LABEL[$key]} (skipped)" ;;
    *)       printf '  %s %s\n'   "$(amber '??')"   "${LABEL[$key]} (did not run)" ;;
  esac
  if [[ "${RESULT[$key]:-}" =~ ^(FAIL|note)$ && -n "${DETAIL[$key]:-}" ]]; then
    printf '%s\n' "${DETAIL[$key]}" | while read -r l; do
      [[ -n "$l" ]] && printf '         %s\n' "$l"
    done
  fi
done

# Notes are counted for the verdict line only — never for the exit status.
notes=0
for key in "${PROCESS_ORDER[@]}"; do
  [[ "${RESULT[$key]:-}" == "note" ]] && notes=$((notes + 1))
done
note_suffix=""
(( notes > 0 )) && note_suffix=" $(amber "($notes note(s) — nothing blocking)")"

printf '\n'
if (( failures > 0 )); then
  printf '%s%s\n' "$(red "$failures check(s) failed")" "$note_suffix"
  (( QUICK )) && printf '%s\n' "$(amber '(quick run: tooling tests and deploy gates were not run)')"
  exit 1
fi
if (( QUICK )); then
  printf '%s — %s%s\n' "$(green 'Everything checked is in place')" \
    "$(amber 'quick run: tooling tests and deploy gates not run')" "$note_suffix"
else
  printf '%s%s\n' "$(green 'Everything in place.')" "$note_suffix"
fi
