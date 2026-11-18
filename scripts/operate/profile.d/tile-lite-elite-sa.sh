# `sa`: the admin CLI, run in the server container. Installed to
# /etc/profile.d/tile-lite-elite-sa.sh (mode 0644) by Turpin's host files
# (app-profile.toml's [[turpin.host_files]]), so every login shell has it.
#
# The container is found by its Compose labels, not by a compose file's path:
# Turpin's compose files are in deploy folders that change with every deploy.
# `docker exec` is a genuinely loopback connection from inside the container,
# which satisfies the server's loopback-only guard on /admin/*.
#
# A function rather than an alias, so that the container is looked up when `sa`
# runs and a missing one is said so. POSIX: /etc/profile reads this with sh too.
sa() {
  _sa_id="$(docker ps -q \
    --filter "label=com.docker.compose.project=tile-lite-elite" \
    --filter "label=com.docker.compose.service=server" | head -n 1)"
  if [ -z "$_sa_id" ]; then
    echo "sa: no running tile-lite-elite server container" >&2
    unset _sa_id
    return 1
  fi
  _sa_tty=""
  if [ -t 0 ]; then _sa_tty="-t"; fi
  # shellcheck disable=SC2086 # _sa_tty is empty or the one flag
  docker exec -i $_sa_tty "$_sa_id" tile-lite-elite-admin "$@"
  _sa_status=$?
  unset _sa_id _sa_tty
  return "$_sa_status"
}
