# shellcheck shell=bash
# nook adopt — pair this machine with a nook, and nook boot — run the boot
# script on a box over SSH instead of typing the one-liner on it directly.
#
# Adopting a second box does not replace the first: each gets its own directory
# under ~/.nook, and `nook use` picks which one commands talk to.

BOOT_URL=${NOOK_BOOT_URL:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh}

cmd_adopt() {
  local host="" name=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --as) name=$2; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) host=$1; shift ;;
    esac
  done
  host=${host:-$(default_nook_host)}
  [[ -n $host ]] || die "usage: nook adopt <host> [--as <name>]"

  need ssh
  need jq
  migrate_single_nook

  log "reaching $host"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" true ||
    die "cannot ssh to $host — is it on the tailnet, and is MagicDNS on?"

  local conf
  conf=$(ssh "$host" cat /etc/nook.conf) ||
    die "$host has no /etc/nook.conf — run the boot script there first, or: nook boot $host"

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
