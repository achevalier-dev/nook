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

# The environment every compose file in the catalogue is written against,
# written next to the stack on the box so compose picks it up there too. That is
# what lets the box upgrade and restart its own services with nothing of yours
# involved — including from a timer, at four in the morning.
service_env() {
  NOOK_TS_IP=$(remote tailscale ip -4 2>/dev/null | head -n1)
  [[ -n $NOOK_TS_IP ]] || die "$NOOK is not on a tailnet — services bind its tailnet address"
  export NOOK_TS_IP NOOK_DATA NOOK_HOST
  export TZ=${TZ:-$(remote timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}
  export DOCKER_CONTEXT=$NOOK_CONTEXT
}

# Where a stack lives on the box. Deliberately the box and not here: a service
# whose compose file only exists on somebody's laptop cannot be restarted,
# upgraded or even looked at without that laptop.
stack_dir() { echo "$NOOK_DATA/stacks/$1"; }

push_stack() { # <name>
  local name=$1 dir
  dir=$(stack_dir "$name")
  remote "sudo install -d -o \$(id -u) -g \$(id -g) $dir"
  remote "cat > $dir/compose.yaml" <"$(services_root)/$name/compose.yaml"
  remote "cat > $dir/.env" <<ENV
NOOK_DATA=$NOOK_DATA
NOOK_TS_IP=$NOOK_TS_IP
NOOK_HOST=$NOOK_HOST
TZ=$TZ
HOME_PORT=$(home_port)
ENV
}

# http://<box> with no port at all is the most memorable address there is, so
# the index takes port 80 whenever the box is not already using it. Decided once
# at install time and recorded, because it must not move underneath a bookmark.
home_port() {
  local recorded
  recorded=$(remote "sed -n 's/^HOME_PORT=//p' $(stack_dir home)/.env 2>/dev/null" | head -n1)
  if [[ -n $recorded ]]; then
    printf '%s\n' "$recorded"
    return 0
  fi
  if [[ -z $(remote "ss -tlnH 'sport = :80' 2>/dev/null" | head -n1) ]]; then
    printf '80\n'
  else
    printf '8880\n'
  fi
}

# The port a service answers on: from the catalogue, except the index, which
# picks its own.
service_port() {
  if [[ $1 == home ]]; then
    home_port
    return 0
  fi
  service_field "$1" port ""
}

# Compose, run on the box against the stack that lives there.
stack_compose() { # <name> <compose args…>
  local name=$1
  shift
  remote "cd $(stack_dir "$name") && docker compose -p $name $*"
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
    port=$(service_port "$name")
    installed=" "
    grep -qx "$name" <<<"$running" && installed="*"
    printf '%s %-14s %-6s %s\n' "$installed" "$name" "${port:-—}" "$summary"
  done < <(known_services)

  echo
  echo "* is running.  nook install <name>   nook uninstall <name>"
}

# One page listing what is running, so nothing depends on remembering that
# Jellyfin is 8096 and Navidrome is 4533. Regenerated after every change,
# because a stale index is worse than none.
# https://<box>.<tailnet>.ts.net when `nook serve` is on, plain host:port when
# it is not. Both work; only one of them is a link you can send to a phone.
service_base() {
  local dns
  if remote sudo tailscale serve status 2>/dev/null | grep -q "https://"; then
    dns=$(remote tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    printf 'https://%s' "$dns"
    return 0
  fi
  printf 'http://%s' "$NOOK_HOST"
  return 1
}

write_home_page() {
  local running name port summary rows="" base tmp n=1
  base=$(service_base || true)
  running=$(running_services)

  local names=()
  mapfile -t names < <(known_services)
  for name in "${names[@]}"; do
    [[ -n $name ]] || continue
    grep -qx "$name" <<<"$running" || continue
    [[ $name == home ]] && continue
    port=$(service_port "$name")
    summary=$(service_field "$name" summary)
    [[ -n $port ]] || continue
    # data-name is what the page uses to grey a service out when the box says
    # it has stopped, so the row is a reading rather than a decoration.
    rows+="<li data-name=\"$name\"><a class=\"line\" href=\"$base:$port\">"
    rows+="<span class=\"num\">$(printf '%02d' "$n")</span>"
    rows+="<span class=\"nm\">$name</span><span class=\"dots\"></span>"
    rows+="<span class=\"pt\">$port</span><span class=\"go\">↗</span></a>"
    rows+="<p class=\"what\">$summary</p></li>"
    n=$((n + 1))
  done

  [[ -n $rows ]] ||
    rows='<li class="empty">Nothing installed yet — <code>nook install jellyfin</code></li>'

  # A bind mount whose source does not exist yet is created by docker as root,
  # and then nothing else can write the page into it.
  remote "sudo install -d -o \$(id -u) -g \$(id -g) $NOOK_DATA/www"

  # Rendered here from a real file rather than assembled in a heredoc: the page
  # is something somebody will want to edit, and HTML inside shell quoting is
  # not something anybody wants to edit.
  tmp=$(mktemp)
  awk -v host="$NOOK_HOST" -v rows="$rows" '
    { gsub(/\{\{HOST\}\}/, host); gsub(/\{\{ROWS\}\}/, rows); print }
  ' "$(services_root)/home/page.html" >"$tmp"
  remote "cat > $NOOK_DATA/www/index.html" <"$tmp"
  rm -f "$tmp"
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
    remote "sudo install -d -o \$(id -u) -g \$(id -g) $NOOK_DATA/apps/$name"
    library=$(service_field "$name" library "")
    [[ -n $library ]] && remote "sudo install -d -o \$(id -u) -g \$(id -g) $NOOK_DATA/$library"

    log "installing $name on $NOOK"
    push_stack "$name"
    stack_compose "$name" up -d

    port=$(service_field "$name" port "")
    if [[ -n $port ]]; then
      notify "$name is up at http://$NOOK_HOST:$port"
    else
      notify "$name is up"
    fi
    [[ -n $library ]] && echo "  its library is $NOOK_DATA/$library — nook push puts things there"
  done

  # The index goes up with the first service, so there is always one address
  # worth bookmarking rather than a list of port numbers to remember.
  if [[ $* != *home* ]] && ! grep -qx home <<<"$(running_services)"; then
    log "adding the index page"
    push_stack home
    stack_compose home up -d >/dev/null 2>&1
  fi
  write_home_page
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
    stack_compose "$name" down
    remote "rm -rf $(stack_dir "$name")"
    echo "$name is gone. Its data is still in $NOOK_DATA/apps/$name —"
    echo "  nook ssh sudo rm -rf $NOOK_DATA/apps/$name   removes that too."
  done
  write_home_page
}

# nook serve — put every running service behind the box's Tailscale name, with a
# real certificate. The tailnet issues one for <box>.<tailnet>.ts.net, so this
# needs nothing bought, renewed or opened on a router.
#
# It proxies to the ports the services already publish rather than moving them
# to loopback: if serve is ever turned off, everything still answers.
cmd_serve() {
  load_config
  need jq

  local dns port name running
  dns=$(remote tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')

  if [[ ${1:-} == --off ]]; then
    remote sudo tailscale serve reset
    write_home_page
    notify "serve is off — services are back to http://$NOOK_HOST:<port>"
    return 0
  fi

  # The certificate is a tailnet-wide setting, and without it serve answers on a
  # name no browser will trust.
  remote "tailscale status --json | jq -e '.CertDomains | length > 0'" >/dev/null 2>&1 ||
    die "this tailnet has no HTTPS certificates.
  Turn them on once, in the admin console under DNS → HTTPS Certificates,
  then run this again."

  NOOK_TS_IP=$(remote tailscale ip -4 | head -n1)
  running=$(running_services)

  # Into an array first: the loop body opens an SSH connection, and ssh reads
  # stdin — which here would be the rest of the list.
  local names=()
  mapfile -t names < <(known_services)

  for name in "${names[@]}"; do
    [[ -n $name ]] || continue
    grep -qx "$name" <<<"$running" || continue
    port=$(service_port "$name")
    [[ -n $port ]] || continue

    if [[ $name == home ]]; then
      # The index answers on 443, because that is the address worth knowing.
      remote sudo tailscale serve --bg --https=443 "http://$NOOK_TS_IP:$port" >/dev/null
      echo "  https://$dns  →  home"
    else
      remote sudo tailscale serve --bg --https="$port" "http://$NOOK_TS_IP:$port" >/dev/null
      echo "  https://$dns:$port  →  $name"
    fi
  done

  write_home_page
  echo
  echo "  Bookmark the first one. It lists the rest, and it is the only address"
  echo "  worth remembering — or use: nook open [service]"
  [[ $(home_port) == 80 ]] &&
    echo "  Without https it is simply http://$NOOK_HOST — no domain, no port."

  # Almost nobody knows this is changeable, and it is the difference between an
  # address you can say out loud and one you have to copy and paste.
  if [[ $dns == *.tail*.ts.net ]]; then
    echo
    echo "  That tailnet is called $(cut -d. -f2- <<<"$dns"). You can rename it to"
    echo "  something you can actually say, once, in the Tailscale admin console"
    echo "  under DNS → Tailnet name:  https://login.tailscale.com/admin/dns"
    echo "  It is a one-time change, and it breaks existing links and"
    echo "  certificates across the whole tailnet — which is why nook will not"
    echo "  do it for you."
  fi
  notify "serving over https at $dns"
}

# nook open — the answer to "what was that address again". Nobody should have to
# hold a tailnet domain and a port number in their head to watch a film.
cmd_open() {
  load_config
  need jq
  local name=${1:-home} port base url

  [[ -d $(services_root)/$name ]] || die "no such service: $name — nook services lists them"
  base=$(service_base || true)
  port=$(service_port "$name")
  [[ -n $port ]] || die "$name has no web interface"

  # http://<box> needs no port, and neither does the served index on 443.
  if [[ $name == home && $port == 80 && $base == http://* ]]; then
    echo "$base"
    command -v xdg-open >/dev/null && xdg-open "$base" >/dev/null 2>&1 &
    return 0
  fi

  # The index answers on 443 once serve is on, so it needs no port.
  if [[ $name == home ]] && [[ $base == https://* ]]; then
    url=$base
  else
    url="$base:$port"
  fi

  echo "$url"
  command -v xdg-open >/dev/null && xdg-open "$url" >/dev/null 2>&1 &
  return 0
}
