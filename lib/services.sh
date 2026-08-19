# shellcheck shell=bash
# A short list of things people actually put on a home server, each one compose
# file in services/, deployed to the nook with one command.
#
# Two conventions hold the catalogue together and are worth keeping:
#
#   - data lives in $NOOK_DATA/apps/<name>, so a box is backed up by copying one
#     directory and a service is removed by deleting one;
#   - a library lives in $NOOK_DATA/files/<something>, which is the shared
#     folder — so `nook push` a film and Jellyfin has it.
#
# Ports bind the box's tailnet address, never 0.0.0.0. Tailscale already
# encrypts and authenticates everything that reaches it, and a home server that
# quietly listens on the café wifi is how people get hurt.

services_root() { echo "$ROOT/services"; }

service_field() { # <name> <json field> [default]
  jq -r --arg d "${3-}" ".$2 // \$d" "$(services_root)/$1/nook.json"
}

known_services() {
  find "$(services_root)" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    while read -r d; do basename "$d"; done | sort
}

# Compose projects already running over there, one per line.
running_services() {
  DOCKER_CONTEXT=$NOOK_CONTEXT docker compose ls --format json 2>/dev/null |
    jq -r '.[].Name' 2>/dev/null || true
}

# The environment every compose file in the catalogue is written against.
service_env() {
  NOOK_TS_IP=$(remote tailscale ip -4 2>/dev/null | head -n1)
  [[ -n $NOOK_TS_IP ]] || die "$NOOK is not on a tailnet — services bind its tailnet address"
  export NOOK_TS_IP NOOK_DATA NOOK_HOST
  export TZ=${TZ:-$(remote timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}
  export DOCKER_CONTEXT=$NOOK_CONTEXT
}

cmd_services() {
  load_config
  need jq
  local name running summary port installed

  running=$(running_services)
  printf '%-16s %-6s %s\n' NAME PORT WHAT
  while read -r name; do
    [[ -n $name ]] || continue
    summary=$(service_field "$name" summary)
    port=$(service_field "$name" port "")
    installed=" "
    grep -qx "$name" <<<"$running" && installed="*"
    printf '%s %-14s %-6s %s\n' "$installed" "$name" "${port:-—}" "$summary"
  done < <(known_services)

  echo
  echo "* is running.  nook install <name>   nook uninstall <name>"
}

cmd_install() {
  load_config
  need jq
  need docker
  [[ ${1:-} ]] || die "usage: nook install <name>…  — nook services lists them"

  local name dir port library
  for name in "$@"; do
    dir=$(services_root)/$name
    [[ -d $dir ]] || die "no such service: $name — nook services lists them"
    service_env

    # Directories are made on the box, not by the container: a bind mount whose
    # source does not exist is created by docker as root, and then the service
    # cannot write to it.
    remote "mkdir -p $NOOK_DATA/apps/$name"
    library=$(service_field "$name" library "")
    [[ -n $library ]] && remote "mkdir -p $NOOK_DATA/$library"

    log "installing $name on $NOOK"
    docker compose --project-name "$name" --project-directory "$dir" up -d

    port=$(service_field "$name" port "")
    if [[ -n $port ]]; then
      notify "$name is up at http://$NOOK_HOST:$port"
    else
      notify "$name is up"
    fi
    [[ -n $library ]] && echo "  its library is $NOOK_DATA/$library — nook push puts things there"
  done
}

# Containers and their images go; the data directory stays, because "uninstall"
# should not be the same word as "delete everything I have put in it".
cmd_uninstall() {
  load_config
  need docker
  [[ ${1:-} ]] || die "usage: nook uninstall <name>"

  local name dir
  for name in "$@"; do
    dir=$(services_root)/$name
    [[ -d $dir ]] || die "no such service: $name"
    service_env
    docker compose --project-name "$name" --project-directory "$dir" down
    echo "$name is gone. Its data is still in $NOOK_DATA/apps/$name —"
    echo "  nook ssh sudo rm -rf $NOOK_DATA/apps/$name   removes that too."
  done
}
