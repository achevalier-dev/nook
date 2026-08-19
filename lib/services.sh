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
ENV
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
    port=$(service_field "$name" port "")
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
  local running name port summary rows="" host=$NOOK_HOST base
  base=$(service_base || true)

  running=$(running_services)
  while read -r name; do
    [[ -n $name ]] || continue
    grep -qx "$name" <<<"$running" || continue
    [[ $name == home ]] && continue
    port=$(service_field "$name" port "")
    summary=$(service_field "$name" summary)
    [[ -n $port ]] || continue
    rows+="<li><a href=\"$base:$port\">$name</a><span>$summary</span></li>"
  done < <(known_services)

  [[ -n $rows ]] || rows="<li><span>Nothing installed yet — <code>nook install jellyfin</code></span></li>"

  # A bind mount whose source does not exist yet is created by docker as root,
  # and then nothing else can write the page into it.
  remote "sudo install -d -o \$(id -u) -g \$(id -g) $NOOK_DATA/www"
  # Deliberately one file with no assets: it has to render from a box that may
  # have nothing else running, and over a link that may be a phone on 4G.
  remote "cat > $NOOK_DATA/www/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$host</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.6 system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; }
  h1 { font-size: 1.4rem; margin-bottom: 0; }
  p.sub { color: #888; margin-top: .2rem; }
  ul { list-style: none; padding: 0; }
  li { display: flex; justify-content: space-between; gap: 1rem; padding: .7rem 0; border-bottom: 1px solid #8883; }
  a { font-weight: 600; text-decoration: none; }
  span { color: #888; text-align: right; }
  footer { color: #888; font-size: .85rem; margin-top: 2rem; }
</style>
<h1>$host</h1>
<p class="sub">everything running on this nook</p>
<ul>$rows</ul>
<footer>Generated by <a href="https://github.com/achevalier-dev/nook">nook</a>. Reachable from anywhere on your tailnet.</footer>
HTML
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
    port=$(service_field "$name" port "")
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

  # Almost nobody knows this is changeable, and it is the difference between an
  # address you can say out loud and one you have to copy and paste.
  if [[ $dns == *.tail*.ts.net ]]; then
    echo
    echo "  That tailnet is called $(cut -d. -f2- <<<"$dns"). You can rename it to"
    echo "  something you can actually say, once, in the Tailscale admin console"
    echo "  under DNS → Tailnet name. Every address above follows it."
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
  port=$(service_field "$name" port "")
  [[ -n $port ]] || die "$name has no web interface"

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
