#!/usr/bin/env bash
set -euo pipefail

# setup-dev-environment.sh — Bootstrap a fresh Ubuntu (WSL2 or otherwise)
# checkout of this repo into a working dev + deploy environment: Rust
# toolchain, wasm target, the exact-matched dioxus-cli/wasm-bindgen-cli
# versions this project needs, sccache, and Docker Engine.
#
# Run this from inside a clone of the repo (it reads Cargo.lock to pick the
# right wasm-bindgen-cli version). Safe to re-run — every step checks
# whether it's already done first.
#
# What this does NOT do, on purpose:
#   - Restore the Oracle deploy SSH key. That's a secret; copy it back in
#     by hand (see docs/3.1-setup.md's "Development Environment Setup").
#   - Enable systemd in WSL. That's a Windows-side /etc/wsl.conf edit
#     needing a `wsl --shutdown`, which a script running inside the distro
#     can't safely trigger on itself. This script checks and warns instead.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: setup-dev-environment.sh

Bootstraps a fresh Ubuntu checkout into a working dev and deploy
environment: Rust toolchain, wasm target, the exact-matched
dioxus-cli and wasm-bindgen-cli versions this project needs, sccache,
Docker Engine, and the shell aliases. Safe to re-run — every step
checks whether it is already done.

It does NOT restore the deploy SSH key (a secret, copied back by hand
— docs/3.1) and it does NOT enable systemd in WSL (a Windows-side
/etc/wsl.conf edit needing `wsl --shutdown`, which a script inside
the distro cannot safely trigger on itself). It checks and warns.

Refuses (exit 1) when:
  - it is run from a linked git worktree
    -> "setup-dev-environment: refusing — this is a linked worktree."
    It writes sadev, sapre, dbdev and the rest for the tree it runs
    in, so from a project worktree they would point at that tree and
    its database, silently. Scripts are operated from main (docs/3.2,
    #389). SETUP_ALLOW_WORKTREE=1 to do it anyway.

Warns without failing when:
  - wasm-bindgen's version cannot be read from Cargo.lock
    -> "could not read wasm-bindgen version from Cargo.lock —
        skipping, install manually"
    A mismatched wasm-bindgen produces a client that builds and does
    not run, so this one is worth acting on.
EOF
  exit 0
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# --- refuse to run from a linked worktree -------------------------------- #389
#
# **This writes aliases for whichever tree it is run from**, because `REPO_DIR`
# is derived from the script's own location — which is right, and is why the
# aliases survived the move to two worktrees without a code change. It is also
# the trap: run this from `projectdev` and `sadev` and `dbdev` quietly point at
# the project worktree and its database, and nothing says so until something
# reads the wrong data.
#
# Owner, 2026-09-21: *"we should be running scripts from main now, unless we
# are testing a new version"*, and *"setup-dev-environment.sh should check
# where it is run."*
#
# **Told apart by git, not by the path.** In the main worktree `--git-dir` and
# `--git-common-dir` are the same; in a linked one the first is
# `<common>/worktrees/<name>`. So a machine with a single checkout — a fresh
# setup, which is this script's main job — is unaffected, and no directory name
# is hardcoded.
#
# It refuses rather than warns because the wrong outcome is silent: a warning
# scrolls past and the aliases are still wrong.
if [ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ]; then
  echo "setup-dev-environment: refusing — this is a linked worktree." >&2
  echo "  $REPO_DIR" >&2
  echo >&2
  echo "  It writes sadev, sapre, dbdev and the rest for the tree it runs in," >&2
  echo "  so from here they would point at the project worktree and its" >&2
  echo "  database. Scripts are operated from main — docs/3.2." >&2
  echo >&2
  echo "  Run it there:" >&2
  echo "    $(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')/scripts/$(basename "$0")" >&2
  echo >&2
  echo "  SETUP_ALLOW_WORKTREE=1 to do it anyway, if that is deliberate." >&2
  [ "${SETUP_ALLOW_WORKTREE:-}" = "1" ] || exit 1
  echo "  SETUP_ALLOW_WORKTREE=1 set — continuing." >&2
fi

echo "==> Checking WSL/systemd (Docker needs systemd to manage its service)"
if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
    if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
        cat <<'EOF'
    WARNING: this looks like WSL without systemd enabled (PID 1 isn't
    systemd). Docker's `systemctl enable --now docker` step will fail.
    Fix: add to /etc/wsl.conf (as root):

        [boot]
        systemd=true

    then from Windows PowerShell: wsl --shutdown
    ...and restart this shell. Continuing anyway in case Docker isn't
    needed on this machine.
EOF
    else
        echo "    systemd OK"
    fi
fi

echo "==> System packages (build tools + dioxus-desktop's webview deps)"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential pkg-config curl ca-certificates git \
    libssl-dev libgtk-3-dev libwebkit2gtk-4.1-dev \
    libayatana-appindicator3-dev librsvg2-dev

echo "==> Rust toolchain"
if ! command -v rustc >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
else
    echo "    already installed: $(rustc --version)"
fi
rustup target add wasm32-unknown-unknown

echo "==> dioxus-cli (must match crates/ui's dioxus/dioxus-web version)"
DIOXUS_VERSION="0.6.3"
if ! command -v dx >/dev/null 2>&1 || [[ "$(dx --version 2>&1)" != *"$DIOXUS_VERSION"* ]]; then
    cargo install dioxus-cli --version "$DIOXUS_VERSION" --locked
else
    echo "    already installed: $(dx --version)"
fi

echo "==> wasm-bindgen-cli (must exactly match the wasm-bindgen crate version in Cargo.lock)"
WASM_BINDGEN_VERSION="$(grep -A1 'name = "wasm-bindgen"' Cargo.lock | grep version | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [ -z "$WASM_BINDGEN_VERSION" ]; then
    echo "    could not read wasm-bindgen version from Cargo.lock — skipping, install manually" >&2
elif ! command -v wasm-bindgen >/dev/null 2>&1 || [[ "$(wasm-bindgen --version 2>&1)" != *"$WASM_BINDGEN_VERSION"* ]]; then
    cargo install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION" --locked
else
    echo "    already installed: $(wasm-bindgen --version)"
fi

echo "==> sccache (speeds up local rebuilds; .cargo/config.toml expects it at ~/.cargo/bin/sccache)"
if ! command -v sccache >/dev/null 2>&1; then
    cargo install sccache --locked
else
    echo "    already installed: $(sccache --version)"
fi

echo "==> Docker Engine"
if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker || echo "    (systemctl failed — see the systemd warning above)"
    sudo usermod -aG docker "$USER"
    echo "    installed — you'll need a new shell session (or 'newgrp docker') for group membership to apply"
else
    echo "    already installed: $(docker --version)"
fi

echo "==> SSH host aliases"
# The deploy scripts pass `-i <key>` explicitly and need none of this. What
# needs it is everything a person types: docs/3.4's `ssh tile-lite-elite`, and
# the dbprod shortcut below. Without a config those resolve `tile-lite-elite`
# as a literal hostname and fail.
#
# The keys themselves are not created here — they are secrets, restored by
# hand from the Windows backup (see the closing note and docs/3.1-setup.md).
# This only names the hosts they open.
if [ -f ~/.ssh/config ] && grep -q "Host tile-lite-elite$" ~/.ssh/config; then
    echo "    already configured"
else
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    cat >> ~/.ssh/config <<'SSHEOF'

# IdentitiesOnly stops the agent offering every key it holds, which otherwise
# burns MaxAuthTries on a host that accepts exactly one.
Host tile-lite-elite
  HostName 129.151.69.246
  User ubuntu
  IdentityFile ~/.ssh/oracle_tile_lite_elite
  IdentitiesOnly yes

Host tile-lite-elite-rehearsal
  HostName 129.151.84.183
  User ubuntu
  IdentityFile ~/.ssh/oracle_tile_lite_elite_rehearsal
  IdentitiesOnly yes

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_gh
  IdentitiesOnly yes
  AddKeysToAgent yes
SSHEOF
    chmod 600 ~/.ssh/config
    echo "    written to ~/.ssh/config"
fi

echo "==> ssh-agent"
# The GitHub key carries a passphrase and the remotes are ssh, so without an
# agent every push asks for it. One agent at a **fixed socket** rather than the
# usual `eval $(ssh-agent)`: that exports a random path into one shell only,
# and anything which does not read ~/.bashrc — a script, or a non-interactive
# shell — then cannot reach it. A known path is reachable by exporting it.
#
# `ssh-add -l` exits 2 only when no agent answers; 1 means a live agent holding
# nothing, which is fine and must not restart it.
if grep -q "tile-lite-elite ssh-agent" ~/.bashrc 2>/dev/null; then
    echo "    already configured"
else
    cat >> ~/.bashrc <<'AGENTEOF'

# >>> tile-lite-elite ssh-agent >>>
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then
  rm -f "$SSH_AUTH_SOCK"
  (umask 077; ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1)
fi
# <<< tile-lite-elite ssh-agent <<<
AGENTEOF
    echo "    written to ~/.bashrc — then 'sshkeys' once per boot"
fi

echo "==> ssh key shortcut (sshkeys)"
# One passphrase prompt per WSL restart is the floor without bridging to the
# Windows agent, and that is a fair price. Remembering three key *filenames* is
# not — none of them is the default `id_ed25519`, so `ssh-add` with no argument
# finds nothing and the error when a key is missing points at the wrong file.
#
# All three together because the deploy keys hit the same wall as GitHub, and
# discovering that halfway through a deploy is worse than loading them up front.
# ssh-add retries the previous passphrase on each subsequent key, so identical
# passphrases mean a single prompt.
sed -i '/alias sshkeys=/d' ~/.bashrc 2>/dev/null || true
echo "alias sshkeys='ssh-add ~/.ssh/id_ed25519_gh ~/.ssh/oracle_tile_lite_elite ~/.ssh/oracle_tile_lite_elite_rehearsal'" >> ~/.bashrc
echo "    written to ~/.bashrc"

echo "==> git hooks"
# The commit-msg hook refuses a subject without the version stamp, at the
# moment it is written rather than six minutes later in CI — and while the
# commit is still the tip, so the fix is an amend rather than a rebase.
#
# core.hooksPath rather than .git/hooks, so the hook is version-controlled and
# a rebuilt machine gets it. CI still runs check-commit-stamp.sh: a hook lives
# in a working copy and --no-verify skips it, so it is a convenience, not a
# gate.
git config core.hooksPath .githooks
echo "    core.hooksPath = .githooks"

echo "==> git: tell it where the agent lives"
# VS Code runs git from a process that never sourced ~/.bashrc, so it has no
# SSH_AUTH_SOCK and falls back to asking for the passphrase on every fetch and
# every push. Setting it inside git's own ssh command fixes that for **any**
# caller — VS Code, cron, a script, a shell that forgot to export it — because
# git supplies the variable itself rather than inheriting it.
#
# Safe when no agent is running: ssh fails to reach the socket and falls back
# to the key file exactly as it would have anyway.
git config --global core.sshCommand 'env SSH_AUTH_SOCK="$HOME/.ssh/agent.sock" ssh'
echo "    core.sshCommand set"

echo "==> Admin CLI aliases (sadev, sapre)"
# The VM has `sa`, written into its ~/.bashrc by deploy.sh, because the admin
# CLI has to run where 127.0.0.1 is the server's own loopback. The same problem
# exists here in two flavours, so there are two aliases rather than one:
#
#   sadev   dev runs natively on :3000, which is the CLI's default, so this is
#           just admin.sh — which also builds the CLI if it is stale.
#   sapre   preview runs in a container, and the host's 127.0.0.1 is not the
#           container's, so admin.sh cannot reach it. It has to run inside.
#
# Delete-then-append, like deploy.sh's, so re-running updates a stale line
# rather than leaving two that disagree.
sed -i '/alias sadev=/d;/alias sapre=/d' ~/.bashrc 2>/dev/null || true
{
  echo "alias sadev='$REPO_DIR/scripts/admin.sh'"
  echo "alias sapre='docker compose -f $REPO_DIR/docker-compose.preview.yml exec server tile-lite-elite-admin'"
} >> ~/.bashrc
echo "    written to ~/.bashrc — new shell, or 'source ~/.bashrc', to pick them up"

echo "==> SQLite shortcuts (dbdev, dbpre, dbprod)"
# For anything the admin CLI does not cover. All three are `-readonly`: an
# inspection session cannot write, whichever environment it lands in, and
# production is one keystroke away from preview.
#
# `dbpre` and `dbprod` run `docker compose exec` **inside the already-running
# `server` container** — sqlite3 has been in the runtime image since #174, so
# no separate container is created and nothing can be left holding the data
# volume (#356). `docker compose exec` allocates a pseudo-tty by default; `-T`
# drops it when a query is given, so `dbpre "select ..."` works in a pipeline
# as well as interactively. If the stack is stopped, `exec` has nothing to
# reach — docs/3.4 documents the throwaway-container fallback for that case.
#
# dbdev is a plain alias because dev's database is a file in the checkout.
python3 - "$REPO_DIR" <<'PYEOF'
import re, sys, pathlib
repo = sys.argv[1]
rc = pathlib.Path.home() / ".bashrc"
text = rc.read_text() if rc.exists() else ""
# Drop any previous block, marked so re-running replaces rather than appends.
text = re.sub(r"\n?# >>> tile-lite-elite sqlite >>>.*?# <<< tile-lite-elite sqlite <<<\n",
              "\n", text, flags=re.S)
block = f'''
# >>> tile-lite-elite sqlite >>>
alias dbdev='sqlite3 -readonly {repo}/data/tile-lite-elite.sqlite3'

dbpre() {{
  local notty=""; [ $# -gt 0 ] && notty="-T"
  docker compose -f {repo}/docker-compose.preview.yml exec $notty server \\
    sqlite3 -readonly /data/tile-lite-elite.sqlite3 "$@"
}}

# Production, over ssh.
dbprod() {{
  ssh -t tile-lite-elite "cd ~/tile-lite-elite && docker compose exec server \\
    sqlite3 -readonly /data/tile-lite-elite.sqlite3"
}}
# <<< tile-lite-elite sqlite <<<
'''
rc.write_text(text.rstrip("\n") + "\n" + block)
print("    written to ~/.bashrc")
PYEOF

cat <<EOF

==> Tooling setup done. Two manual steps left (see docs/3.1-setup.md):
    1. Copy your Oracle deploy SSH key back in:
         ~/.ssh/oracle_tile_lite_elite (private) and .pub — from your Windows backup.
    2. Start a new shell (for the docker group to take effect), then verify:
         cargo test --workspace
         dx --version
         docker compose version
         ssh -i ~/.ssh/oracle_tile_lite_elite ubuntu@129.151.69.246 echo ok
EOF
