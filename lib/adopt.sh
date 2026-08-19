# shellcheck shell=bash
# nook adopt — pair this machine with a nook, and nook boot — run the boot
# script on a Pi over SSH instead of typing the one-liner on the Pi itself.

BOOT_URL=${NOOK_BOOT_URL:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh}

cmd_adopt() {
  local host=${1:-nook}
  need ssh
  need jq

  log "reaching $host"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" true ||
    die "cannot ssh to $host — is it on the tailnet, and is MagicDNS on?"

  local conf
  conf=$(ssh "$host" cat /etc/nook.conf) ||
    die "$host has no /etc/nook.conf — run the boot script there first, or: nook boot $host"

  mkdir -p "$NOOK_HOME"
  {
    echo "# written by nook adopt on $(date -Is)"
    echo "NOOK_HOST=$host"
    echo "$conf"
  } >"$NOOK_CONFIG"
  load_config

  adopt_ssh_config
  # NBD has no per-initiator ACLs, so there is nothing to register for it.
  if [[ $NOOK_TRANSPORT == iscsi ]]; then
    adopt_iscsi_initiator
  fi
  adopt_docker_context
  adopt_mount_unit
  adopt_bookmark

  notify "adopted $host"
  cat <<EOF

next:
  nook mount     $NOOK_DATA/files at $NOOK_MOUNT — shared, many machines
  nook attach    the drive as a real block device — yours alone while attached
  nook up <dir>  run a compose file from here, on the nook
EOF
}

# Its own marked block so re-adopting replaces it instead of stacking copies,
# and so the rest of the file is never touched.
adopt_ssh_config() {
  local file="$HOME/.ssh/config"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [[ -f $file ]] || : >"$file"
  chmod 600 "$file"

  replace_block "$file" "# >>> nook" "# <<< nook" prepend <<EOF
Host $NOOK_HOST
	HostName $NOOK_HOST
	# One connection reused by every nook command. A fresh handshake per call is
	# what makes a status widget feel heavy.
	ControlMaster auto
	ControlPath ~/.ssh/nook-%r@%h:%p
	ControlPersist 5m
	ServerAliveInterval 15
	ServerAliveCountMax 3
EOF
  log "ssh config updated ($file)"
}

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
  if docker context inspect nook >/dev/null 2>&1; then
    docker context update nook --docker "host=ssh://$NOOK_HOST" >/dev/null
  else
    docker context create nook --docker "host=ssh://$NOOK_HOST" >/dev/null
  fi
  log "docker context \"nook\" points at ssh://$NOOK_HOST"
}

adopt_mount_unit() {
  systemctl --user enable nook-mount.service >/dev/null 2>&1 ||
    log "nook-mount.service is not installed — run ./install.sh"
}

# So the folder lands in the file manager sidebar rather than only in $HOME.
adopt_bookmark() {
  local file="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"
  mkdir -p "$(dirname "$file")"
  [[ -f $file ]] || : >"$file"
  grep -qxF "file://$NOOK_MOUNT nook" "$file" ||
    printf 'file://%s nook\n' "$NOOK_MOUNT" >>"$file"
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
