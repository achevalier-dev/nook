# shellcheck shell=bash
# nook adopt — pair this machine with a nook, and nook boot — run the boot
# script on a box over SSH instead of typing the one-liner on it directly.
#
# Adopting a second box does not replace the first: each gets its own directory
# under ~/.nook, and `nook use` picks which one commands talk to.

BOOT_URL=${NOOK_BOOT_URL:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh}

# Accounts a box is likely to have, in the order worth trying. The local name
# first — on a box you set up yourself it is usually the same one — then the
# defaults the common images ship with.
adopt_candidate_users() {
  printf '%s\n' "$(id -un)" admin pi ubuntu debian root | awk '!seen[$0]++'
}

# A Tailscale peer has already been authenticated by the tailnet: WireGuard keys
# and device identity, checked before a packet moves. Trusting the SSH host key
# on first contact adds nothing to that and removes the one question a script
# cannot answer for you. Anywhere else, ssh asks in the usual way.
adopt_ssh_opts() {
  local host=$1
  printf '%s\n' -o ConnectTimeout=8 -o BatchMode=yes
  if tailnet_peer "$host" >/dev/null 2>&1; then
    printf '%s\n' -o StrictHostKeyChecking=accept-new
  fi
}

tailnet_peer() {
  command -v tailscale >/dev/null || return 1
  command -v jq >/dev/null || return 1
  tailscale status --json 2>/dev/null |
    jq -e --arg h "$1" '.Peer[]? | select((.HostName == $h or (.DNSName | startswith($h + "."))) and .Online)' >/dev/null
}

# Which account on that box answers. Nothing here asks for a password: BatchMode
# means a box that wants one fails fast rather than hanging on a prompt.
adopt_find_user() {
  local host=$1 user opts
  mapfile -t opts < <(adopt_ssh_opts "$host")
  while read -r user; do
    if ssh -n "${opts[@]}" -l "$user" "$host" true 2>/dev/null; then
      printf '%s\n' "$user"
      return 0
    fi
  done < <(adopt_candidate_users)
  return 1
}

# Every online machine in the tailnet that answers with a nook config. Cheap
# enough to just do: one SSH probe per online peer, eight seconds at worst.
adopt_discover() {
  local host user opts found=0
  command -v tailscale >/dev/null || return 1

  while read -r host; do
    [[ -n $host ]] || continue
    user=$(adopt_find_user "$host") || continue
    mapfile -t opts < <(adopt_ssh_opts "$host")
    ssh -n "${opts[@]}" -l "$user" "$host" test -f /etc/nook.conf 2>/dev/null || continue
    printf '%s@%s\n' "$user" "$host"
    found=1
  done < <(tailscale status --json 2>/dev/null |
    jq -r '.Peer[]? | select(.Online) | .HostName' | sort -u)

  ((found))
}

cmd_adopt() {
  local host="" name="" user=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --as) name=$2; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) host=$1; shift ;;
    esac
  done

  need ssh
  need jq
  migrate_single_nook

  # No argument: re-read the box already adopted, or go and find one.
  [[ -n $host ]] || host=$(default_nook_host)
  if [[ -z $host ]]; then
    log "looking for a nook on your tailnet"
    local found=()
    mapfile -t found < <(adopt_discover || true)
    case ${#found[@]} in
      0) nothing_found ;;
      1)
        host=${found[0]}
        log "found ${host}"
        ;;
      *)
        echo "nook: more than one box on this tailnet is a nook:" >&2
        printf '  %s\n' "${found[@]}" >&2
        echo >&2
        echo "  Adopt them one at a time:  nook adopt ${found[0]}" >&2
        exit 1
        ;;
    esac
  fi

  # The account on the box is rarely the one you are logged in as here — a Pi
  # image ships with its own user — so it may be given, and is remembered.
  if [[ $host == *@* ]]; then
    user=${host%%@*}
    host=${host#*@}
  fi

  log "reaching $host"
  local opts
  mapfile -t opts < <(adopt_ssh_opts "$host")
  if [[ -z $user ]]; then
    user=$(adopt_find_user "$host") || unreachable "$host" ""
    [[ $user == "$(id -un)" ]] || log "signing in as $user"
  elif ! ssh -n "${opts[@]}" -l "$user" "$host" true 2>/dev/null; then
    unreachable "$host" "$user"
  fi

  local conf
  conf=$(ssh "${opts[@]}" -l "$user" "$host" cat /etc/nook.conf 2>/dev/null) ||
    die "$host has no /etc/nook.conf — run the boot script there first, or: nook boot $user@$host"

  # The box names itself. Two boxes that both answer to "nook" need --as, and
  # say so rather than quietly overwriting each other.
  name=${name:-$(sed -n 's/^NOOK_NAME=//p' <<<"$conf" | head -n1)}
  name=${name:-$host}
  local dir
  dir=$(nook_dir "$name")
  if [[ -f $dir/config ]]; then
    local existing
    existing=$(sed -n 's/^NOOK_HOST=//p' "$dir/config" | head -n1)
    [[ $existing == "$host" ]] ||
      die "a different nook is already called '$name' ($existing) — adopt this one with --as <other-name>"
  fi

  mkdir -p "$dir"
  {
    echo "# written by nook adopt on $(date -Is)"
    echo "NOOK_HOST=$host"
    echo "NOOK_SSH_USER=$user"
    printf '%s\n' "$conf"
  } >"$dir/config"

  # The first one adopted becomes the default; later ones do not steal it.
  [[ -f $NOOK_HOME/default ]] || printf '%s\n' "$name" >"$NOOK_HOME/default"

  NOOK=$name
  load_config

  write_ssh_config
  log "ssh config updated ($HOME/.ssh/config)"
  if [[ $NOOK_TRANSPORT == iscsi ]]; then
    adopt_iscsi_initiator
  fi
  adopt_docker_context
  adopt_mount_unit
  adopt_bookmark

  notify "adopted $name"
  cat <<EOF

next:
  nook mount     $NOOK_DATA/files at $NOOK_MOUNT — shared, many machines
  nook attach    the drive as a real block device — yours alone while attached
  nook up <dir>  run a compose file from here, on $name
EOF
  local others
  others=$(nooks | grep -vx "$name" | paste -sd' ' || true)
  if [[ -n $others ]]; then
    echo "  nook use $name   — commands go to $(default_nook) until you do"
  fi
}

nothing_found() {
  echo "nook: no box on this tailnet has run the boot script yet." >&2
  echo >&2
  if ! command -v tailscale >/dev/null; then
    echo "  tailscale is not installed here, and that is how nook reaches a box." >&2
    echo "  https://tailscale.com/download" >&2
  elif ! tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then
    echo "  This machine is not on a tailnet yet:  sudo tailscale up" >&2
  else
    echo "  Online machines on your tailnet right now:" >&2
    tailscale status --json | jq -r '.Peer[]? | select(.Online) | "    " + .HostName' >&2
    echo >&2
    echo "  On the one you want, run:" >&2
    echo "    curl -fsSL $BOOT_URL | bash" >&2
    echo "  or from here, if it already takes SSH:  nook boot <host>" >&2
  fi
  exit 1
}

# "cannot ssh" has three quite different causes and only one of them is the box.
# Naming the right one is the difference between a five-second fix and an hour.
unreachable() {
  local host=$1 user=${2:-} state=""
  echo "nook: cannot reach $host" >&2

  if ! command -v tailscale >/dev/null; then
    echo "  tailscale is not installed here, and that is how nook reaches a box." >&2
    echo "  https://tailscale.com/download" >&2
    exit 1
  fi

  state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "Unknown"')
  if [[ $state != Running ]]; then
    echo "  this machine is not on a tailnet (tailscale says: $state)." >&2
    echo "  Sign in with the same account as the box:  sudo tailscale up" >&2
    exit 1
  fi

  if ! tailscale status --json | jq -e --arg h "$host" '.Peer[]? | select(.HostName == $h)' >/dev/null; then
    echo "  no machine called \"$host\" is in this tailnet." >&2
    echo "  Check the name in the Tailscale admin console, or that the box finished its boot script." >&2
    exit 1
  fi

  if ! tailscale status --json | jq -e --arg h "$host" '.Peer[]? | select(.HostName == $h and .Online)' >/dev/null; then
    echo "  $host is in the tailnet but offline. Is it powered on?" >&2
    exit 1
  fi

  echo "  $host is online but not answering SSH." >&2
  echo >&2
  echo "  Try it by hand — that shows the real reason, and answers the host key" >&2
  echo "  question that a script cannot answer for you:" >&2
  echo "      ssh ${user:+$user@}$host" >&2
  echo >&2
  echo "  If it says the account does not exist, name the one on the box:" >&2
  echo "      nook adopt admin@$host" >&2
  echo "  If it hangs or is refused, the box needs 'tailscale up --ssh' — its boot" >&2
  echo "  script does that, so check the run finished: journalctl -u nook-boot" >&2
  exit 1
}

# `nook adopt` with no argument re-reads the current default's config, which is
# how a box that changed transport or data path gets picked up.
default_nook_host() {
  local name
  name=$(default_nook 2>/dev/null) || return 0
  sed -n 's/^NOOK_HOST=//p' "$(nook_dir "$name")/config" 2>/dev/null | head -n1
}

# One initiator name per machine, shared by every nook it attaches; the ACL that
# uses it lives on each box separately.
adopt_iscsi_initiator() {
  need iscsiadm "open-iscsi"
  local file=/etc/iscsi/initiatorname.iscsi
  if ! grep -qxF "InitiatorName=$NOOK_INITIATOR_IQN" "$file" 2>/dev/null; then
    log "setting this machine's iSCSI name (needs sudo)"
    printf 'InitiatorName=%s\n' "$NOOK_INITIATOR_IQN" | sudo tee "$file" >/dev/null
    sudo systemctl restart iscsid 2>/dev/null || true
  fi
  sudo systemctl enable --now iscsid >/dev/null
  # NBD has no ACLs, so this half only exists on iSCSI: without it the target
  # refuses this machine by design.
  remote sudo nook-target allow "$NOOK_INITIATOR_IQN"
}

adopt_docker_context() {
  command -v docker >/dev/null || return 0
  if docker context inspect "$NOOK_CONTEXT" >/dev/null 2>&1; then
    docker context update "$NOOK_CONTEXT" --docker "host=ssh://$NOOK_HOST" >/dev/null
  else
    docker context create "$NOOK_CONTEXT" --docker "host=ssh://$NOOK_HOST" >/dev/null
  fi
  log "docker context \"$NOOK_CONTEXT\" points at ssh://$NOOK_HOST"
}

adopt_mount_unit() {
  systemctl --user enable "nook-mount@$NOOK.service" >/dev/null 2>&1 ||
    log "nook-mount@.service is not installed — run ./install.sh"
}

# The parent, not the mount itself: with more than one nook the sidebar wants
# one entry holding them all, not an entry per box.
adopt_bookmark() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks" parent
  parent=$(dirname "$NOOK_MOUNT")
  mkdir -p "$(dirname "$file")" "$parent"
  [[ -f $file ]] || : >"$file"
  grep -qxF "file://$parent nook" "$file" ||
    printf 'file://%s nook\n' "$parent" >>"$file"
}

# Everything after `--` goes to the boot script, so this stays a pipe rather
# than a second copy of its flag parsing.
cmd_boot() {
  local host=${1:-}
  [[ -n $host ]] || die "usage: nook boot <host> [-- <boot flags>]"
  shift
  [[ ${1:-} == -- ]] && shift

  need ssh
  ssh -o ConnectTimeout=10 -t "$host" \
    "curl -fsSL $BOOT_URL | bash -s -- $*" ||
    die "the boot script did not finish on $host"

  log "booted $host — adopting it here"
  cmd_adopt "$host"
}
