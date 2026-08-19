# shellcheck shell=bash
# Compose files stay on this machine; the containers run on the nook. All of it
# is the `nook` docker context over the same reused SSH connection.

_compose() {
  need docker
  load_config
  DOCKER_CONTEXT=$NOOK_CONTEXT docker compose --project-directory "$1" "${@:2}"
}

cmd_up() { _compose "${1:-.}" up -d --remove-orphans; }
cmd_down() { _compose "${1:-.}" down; }

cmd_ps() {
  need docker
  load_config
  DOCKER_CONTEXT=$NOOK_CONTEXT docker ps
}

# The argument is a compose service, because that is what the compose file in
# front of you calls it — `docker logs` wants the container name compose
# generated, which is a different string nobody typed.
cmd_logs() {
  need docker
  load_config
  local dir=${2:-.}
  if DOCKER_CONTEXT=$NOOK_CONTEXT docker compose --project-directory "$dir" \
    logs -f --tail 100 ${1:+"$1"} 2>/dev/null; then
    return 0
  fi
  # Not in a project directory, so treat it as a container name after all.
  [[ -n ${1:-} ]] || die "no compose project here — name a container, or run this where the compose file is"
  DOCKER_CONTEXT=$NOOK_CONTEXT docker logs -f --tail 100 "$1"
}
