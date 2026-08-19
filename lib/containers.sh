# shellcheck shell=bash
# Compose files stay on this machine; the containers run on the nook. All of it
# is the `nook` docker context over the same reused SSH connection.

_compose() {
  need docker
  load_config
  DOCKER_CONTEXT=nook docker compose --project-directory "$1" "${@:2}"
}

cmd_up() { _compose "${1:-.}" up -d --remove-orphans; }
cmd_down() { _compose "${1:-.}" down; }

cmd_ps() {
  need docker
  load_config
  DOCKER_CONTEXT=nook docker ps
}

cmd_logs() {
  need docker
  load_config
  if [[ -z ${1:-} ]]; then
    DOCKER_CONTEXT=nook docker compose logs -f --tail 100
    return
  fi
  DOCKER_CONTEXT=nook docker logs -f --tail 100 "$1"
}
