#!/usr/bin/env bash
# Sourced by deploy.sh and rollback.sh. Not executable on its own.
#
# Proves the deploy key works before anything expensive happens.
#
# Why it exists: the deploy keys carry passphrases, so they are only usable
# while an agent holds them, and every ssh call in these scripts passes `-n`
# (stdin closed, so a prompt is impossible — see the SSH_OPTS comment beside
# each). The failure is therefore a bare "Permission denied (publickey)" that
# says nothing about a locked key. Worse, deploy.sh's first remote contact is
# the scp *after* the build, so a forgotten `ssh-add` cost three minutes and
# then a misleading error.
#
# Shared rather than copied because the diagnosis below is the whole value: two
# copies would drift, and the one that drifts is the one somebody reads at
# 11pm during a failed deploy.

# require_ssh_access <key> <user@host>
require_ssh_access() {
  local key="$1" remote="$2"

  # BatchMode makes "never prompt" certain rather than incidental — `-n` alone
  # depends on how the script was invoked.
  if ssh -n -i "$key" -o ConnectTimeout=10 -o BatchMode=yes "$remote" true 2>/dev/null; then
    return 0
  fi

  echo "==> Cannot authenticate to $remote with $key" >&2

  local fingerprint=""
  [ -f "$key.pub" ] && fingerprint="$(ssh-keygen -lf "$key.pub" 2>/dev/null | awk '{print $2}')"

  if ! ssh-add -l >/dev/null 2>&1 && [ $? -eq 2 ]; then
    echo "    No agent is reachable. Start a new shell, then:" >&2
    echo "      ssh-add $key" >&2
    echo "    A script that does not read ~/.bashrc needs the socket exported:" >&2
    echo "      export SSH_AUTH_SOCK=\$HOME/.ssh/agent.sock" >&2
  elif [ -n "$fingerprint" ] && ! ssh-add -l 2>/dev/null | grep -qF "$fingerprint"; then
    echo "    An agent is running but does not hold this key. Load it with:" >&2
    echo "      ssh-add $key" >&2
  else
    echo "    The key is loaded, so this is the host rather than the key —" >&2
    echo "    check it is up and that its authorized_keys still has this key." >&2
  fi
  return 1
}
