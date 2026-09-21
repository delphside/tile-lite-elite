#!/usr/bin/env bash
# run-log.sh — a machine-readable record of a script run that outlives the
# terminal. #328.
#
# **Sourced, never executed.** It adds a second channel and changes nothing a
# person sees (#328 R3): every `echo` a script already writes still goes to the
# terminal exactly as before.
#
#   . "$(dirname "$0")/run-log.sh"
#   run_log_start deploy.sh "$@"
#   run_log_event "gate passed" gate=milestone
#   # the exit status is recorded by the trap run_log_start installs
#
# **Outside the repository**, at `${XDG_STATE_HOME:-~/.local/state}/tile-lite-elite/`.
# A path inside it would put `main`'s record and `projectdev`'s in different
# directories, so *"has this failed before"* would be answered from whichever
# worktree you happened to be standing in — which is the failure this exists to
# fix, in a new place. It also survives `git clean` and needs no `.gitignore`
# entry to remember.
#
# **One file per run, pruned to the last 20 per script.** The question is *"what
# did it say the last time it went wrong"*, which is a whole run — not a grep
# across interleaved ones. Twenty is about a month at four releases a fortnight.
#
# **Identifiers only**, as `docs/4.7` requires of the server: no password, no
# token, no PAR url. `run_log_event` takes `key=value` pairs and writes them as
# they are, so a caller passing a secret writes a secret — the rule is the
# caller's to keep, and `check-log-hygiene.py` is what checks it.

RUN_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tile-lite-elite"
RUN_LOG_KEEP="${RUN_LOG_KEEP:-20}"
RUN_LOG_FILE=""
RUN_LOG_SCRIPT=""

run_log_now() { date -u +%Y-%m-%dT%H:%M:%S.%6NZ; }

# Everything after the first key=value is written verbatim. jq is not assumed:
# this repository has had none installed on the dev machine since #329, and a
# logger that needs a tool the scripts do not have is a logger that silently
# does nothing.
run_log_json() {
  local message="$1"; shift
  local out="{\"timestamp\":\"$(run_log_now)\",\"level\":\"INFO\",\"message\":\"$message\""
  out+=",\"script\":\"$RUN_LOG_SCRIPT\""
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    # Quotes and backslashes only. A newline in a value would break the line
    # format, so it is replaced rather than escaped -- a record that cannot be
    # read line by line is not machine-readable.
    value="${value//\\/\\\\}"; value="${value//\"/\\\"}"; value="${value//$'\n'/ }"
    out+=",\"$key\":\"$value\""
  done
  printf '%s}\n' "$out"
}

run_log_event() {
  [[ -n "$RUN_LOG_FILE" ]] || return 0
  run_log_json "$@" >> "$RUN_LOG_FILE" 2>/dev/null || true
}

# The exit status is the fact worth having, and a script that fails does not
# reach its own last line -- so it is recorded by a trap rather than by the
# caller remembering.
# **Takes the status, or reads it.** In a chained trap -- `cleanup; run_log_finish`
# -- `$?` is `cleanup`'s status, not the script's, so the outcome recorded was
# whatever the cleanup returned. Found by the test on 2026-09-21, which is what
# the test was for. The status is captured first and passed in.
run_log_finish() {
  local status="${1:-$?}"
  run_log_event "run finished" "status=$status"
  return "$status"
}

run_log_start() {
  RUN_LOG_SCRIPT="${1:-unknown}"; shift || true
  mkdir -p "$RUN_LOG_DIR" 2>/dev/null || return 0
  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  RUN_LOG_FILE="$RUN_LOG_DIR/${RUN_LOG_SCRIPT%.sh}-$run_id.jsonl"
  run_log_event "run started" "args=$*" "commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  run_log_install_trap
  run_log_prune
}

# **Chained, never replaced.** A caller that already has an EXIT trap keeps it;
# one that sets a trap *after* this must chain by hand, and the note below says
# so — `deploy.sh` sets `trap cleanup EXIT` 1,300 lines after it would source
# this, so an unchained trap there would silently drop the outcome of every
# deploy, which is the one run this exists for.
run_log_install_trap() {
  local existing
  existing="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
  if [[ -n "$existing" && "$existing" != *run_log_finish* ]]; then
    trap "_run_log_st=\$?; $existing; run_log_finish \$_run_log_st" EXIT
  else
    trap '_run_log_st=$?; run_log_finish $_run_log_st' EXIT
  fi
}

# Oldest first, deleting all but the newest RUN_LOG_KEEP for *this* script. Per
# script rather than overall: a busy deploy week must not evict the last time
# restore-backup.sh ran, which is exactly when somebody asks.
run_log_prune() {
  local prefix="$RUN_LOG_DIR/${RUN_LOG_SCRIPT%.sh}-"
  local -a old
  mapfile -t old < <(ls -1t "$prefix"*.jsonl 2>/dev/null | tail -n +"$((RUN_LOG_KEEP + 1))")
  [[ ${#old[@]} -gt 0 ]] && rm -f "${old[@]}" 2>/dev/null
  return 0
}

run_log_path() { printf '%s\n' "$RUN_LOG_FILE"; }

# **If your script sets an EXIT trap after calling `run_log_start`, chain it:**
#
#   trap 'st=$?; cleanup; run_log_finish $st' EXIT
#
# The status must be captured **before** the cleanup: inside the trap, `$?` is
# the previous command's status, so `cleanup; run_log_finish` records whatever
# the cleanup returned rather than what the script exited with.
#
# Bash keeps one EXIT trap. A later `trap cleanup EXIT` replaces this one and
# the run's outcome is never written -- silently, and only for the runs that
# reached that line, which are the successful ones. `run_log_finish` is safe to
# call twice: the second call writes a second `run finished` line rather than
# failing, and two lines are a smaller fault than none.
