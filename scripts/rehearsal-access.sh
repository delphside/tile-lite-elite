#!/usr/bin/env bash
set -euo pipefail

# rehearsal-access.sh — let a device into rehearsal, and take every device out.
#
#   ./scripts/rehearsal-access.sh grant    # print the unlock URL, as a QR code
#   ./scripts/rehearsal-access.sh revoke   # rotate the secret: all devices out
#   ./scripts/rehearsal-access.sh status   # is a key configured, and is it live
#
# Rehearsal is a public site that may hold a clone of production's database
# (#240), so it is closed by default: the Caddyfile refuses every request for
# rehearsal's hostnames unless the browser carries a cookie holding the host's
# `REHEARSAL_ACCESS_KEY`. Production is untouched — the gate is matched on hostname,
# so it cannot fire there.
#
# **A cookie can only be set by the browser that will hold it**, so this script
# cannot grant access on its own. What it does is produce the URL a device
# visits, and take the secret away. That is why `grant` prints something to
# scan rather than reporting success.
#
# **`grant` deliberately does not rotate.** Unlocking the phone would otherwise
# lock out the laptop, and rehearsal is tested from both. One secret, several
# devices, and the cookie's own four-hour expiry ends each session separately.
#
# Run from here, over ssh, like every other rehearsal script — not on the VM.
# A script that must be run *on* the box is one more thing to be logged into
# and one more copy to drift.

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/rehearsal-target.sh
. "$HERE/rehearsal-target.sh"

# The value docker-compose.yml falls back to when the host's .env has no key.
# Chosen to be a string nobody would hold as a cookie, so a rehearsal that was
# never configured is *locked* rather than open — see the comment there.
SENTINEL="no-rehearsal-key-configured"
UNLOCK_HOST="rehearsal.tileliteelite.com"

remote() {
  ssh -n -i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
    "$DEPLOY_USER@$DEPLOY_HOST" "$@"
}

# The key as the *running container* would see it: the .env value if there is
# one, the sentinel otherwise. Read rather than assumed, because a key written
# to .env but never applied is exactly the state that looks configured and
# behaves locked.
configured_key() {
  remote "cd $DEPLOY_REMOTE_DIR && grep -m1 '^REHEARSAL_ACCESS_KEY=' .env 2>/dev/null | cut -d= -f2-" \
    || true
}

live_key() {
  remote "cd $DEPLOY_REMOTE_DIR && docker compose exec -T web printenv REHEARSAL_ACCESS_KEY 2>/dev/null" \
    || true
}

new_key() {
  # Hex, so it survives a URL, a QR code and a Set-Cookie header without
  # escaping — the three places it has to travel.
  remote "openssl rand -hex 24"
}

write_key() {
  local key="$1"
  # Rewrite the line if it is there, append it if it is not. `docker compose
  # up -d web` rather than `restart`: restart reuses the container's existing
  # environment, so it would report success and change nothing.
  remote "cd $DEPLOY_REMOTE_DIR \
    && touch .env \
    && sed -i '/^REHEARSAL_ACCESS_KEY=/d' .env \
    && echo 'REHEARSAL_ACCESS_KEY=$key' >> .env \
    && docker compose up -d web > /dev/null 2>&1 \
    && echo applied"
}

show_unlock() {
  # Two statements, not one `local key=... url=...`: under `set -u` the second
  # assignment on such a line expands `$key` from the *outer* scope, which does
  # not exist, and the script aborts. Found by the test harness running with
  # the same options the script does.
  local key="$1"
  local url="https://$UNLOCK_HOST/unlock/$key"
  echo
  if command -v qrencode > /dev/null; then
    qrencode -t ANSIUTF8 "$url"
    echo "    Scan the code with the device you want to let in."
  else
    echo "    qrencode is not installed, so here is the URL to open by hand:"
    echo "    (apt install qrencode, and this prints a code the phone can scan)"
  fi
  echo
  echo "    $url"
  echo
  echo "    It opens the site directly — access lasts 4 hours on that device,"
  echo "    then ends by itself."
}

case "${1:-}" in
  grant)
    KEY="$(configured_key)"
    if [[ -z "$KEY" || "$KEY" == "$SENTINEL" ]]; then
      echo "==> No key configured on rehearsal — generating one"
      KEY="$(new_key)"
      [[ -n "$KEY" ]] || { echo "rehearsal-access: could not generate a key" >&2; exit 1; }
      [[ "$(write_key "$KEY")" == "applied" ]] \
        || { echo "rehearsal-access: could not write the key to the host" >&2; exit 1; }
      echo "    written to $DEPLOY_REMOTE_DIR/.env and applied"
    fi
    show_unlock "$KEY"
    ;;

  revoke)
    echo "==> Rotating rehearsal's access key — every device is locked out"
    KEY="$(new_key)"
    [[ -n "$KEY" ]] || { echo "rehearsal-access: could not generate a key" >&2; exit 1; }
    [[ "$(write_key "$KEY")" == "applied" ]] \
      || { echo "rehearsal-access: could not write the key to the host" >&2; exit 1; }
    echo "    done. Run 'grant' to let a device back in."
    ;;

  status)
    CONFIGURED="$(configured_key)"
    LIVE="$(live_key)"
    if [[ -z "$CONFIGURED" ]]; then
      echo "    .env:      no REHEARSAL_ACCESS_KEY — rehearsal is locked to everybody"
    elif [[ "$CONFIGURED" == "$SENTINEL" ]]; then
      echo "    .env:      the sentinel — rehearsal is locked to everybody"
    else
      echo "    .env:      a key is set"
    fi
    # The two disagreeing means the key was written but never applied, which
    # reads exactly like a wrong key when a device is refused.
    if [[ -z "$LIVE" ]]; then
      echo "    container: could not be read — is the web container running?"
    elif [[ "$LIVE" == "$SENTINEL" ]]; then
      echo "    container: running on the sentinel — locked"
    elif [[ "$LIVE" != "$CONFIGURED" ]]; then
      echo "    container: running a DIFFERENT key from .env — the file was" >&2
      echo "               changed without 'docker compose up -d web'." >&2
      exit 1
    else
      echo "    container: running the key from .env"
    fi
    ;;

  -h|--help)
    cat <<'EOF'
usage: rehearsal-access.sh grant    # print the unlock URL, as a QR code
       rehearsal-access.sh revoke   # rotate the secret: all devices out
       rehearsal-access.sh status   # is a key configured, and is it live

Rehearsal is closed by default (#240): the Caddyfile refuses every
request for rehearsal's hostnames without a cookie holding the host's
REHEARSAL_ACCESS_KEY. A cookie can only be set by the browser that
will hold it, so this prints something to scan rather than reporting
success. `grant` deliberately does not rotate — unlocking the phone
would otherwise lock out the laptop.

Refuses (exit 2) when:
  - no verb, or one that is not grant/revoke/status, is given
    -> the usage above

Refuses (exit 1) when:
  - `grant` or `revoke` cannot generate a key on the host
    -> "rehearsal-access: could not generate a key"
  - the new key cannot be written to the host's .env and applied
    -> "rehearsal-access: could not write the key to the host"
  - `status` finds the container running a different key from .env
    -> "container: running a DIFFERENT key from .env — the file was
        changed without 'docker compose up -d web'."
    This reads exactly like a wrong key when a device is refused,
    which is why it is a refusal and not a line of output.

`status` exits 0 for every other state it reports, including a
rehearsal with no key at all: locked to everybody is a configuration,
not a fault.
EOF
    exit 0
    ;;

  *)
    sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//'
    echo
    echo "  './scripts/rehearsal-access.sh --help' lists what each verb refuses."
    exit 2
    ;;
esac
