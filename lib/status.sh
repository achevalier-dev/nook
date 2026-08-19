# shellcheck shell=bash
# nook status — one screen of the nook's own numbers plus what this machine
# holds. nook doctor — every moving part, named individually.
#
# Needs lib/drive.sh sourced alongside it for disk_device.

cmd_status() {
  need jq
  load_config

  local json
  json=$(remote nook-info 2>/dev/null) || die "$NOOK_HOST is not answering"

  if [[ ${1:-} == --json ]]; then
    printf '%s\n' "$json"
    return 0
  fi

  jq -r '
    "host       \(.name)  ·  up \(.uptime)",
    "load       \(.load)   temp \(.temp)°C",
    "disk       \((.disk.used/1073741824)|floor)G used of \((.disk.size/1073741824)|floor)G  ·  \((.disk.avail/1073741824)|floor)G free",
    "containers \(.containers) running",
    "drive      \(.transport), \(if .attached > 0 then "attached by \(.attached)" else "free" end)"
  ' <<<"$json"

  if mountpoint -q "$NOOK_MOUNT"; then
    echo "folder     mounted at $NOOK_MOUNT"
  else
    echo "folder     not mounted"
  fi

  local dev at
  dev=$(disk_device || true)
  if [[ -n $dev ]]; then
    at=$(mounted_at "$dev")
    echo "drive here $dev${at:+ at $at}"
  fi
}

# Prints every check even when an early one fails: "ssh is down" and "sshfs is
# missing" are different problems and the second is worth knowing about now.
cmd_doctor() {
  load_config
  local bad=0
  check() { printf '%-13s %s\n' "$1" "$2"; }

  if command -v tailscale >/dev/null; then
    local peer
    peer=$(tailscale status --json 2>/dev/null |
      jq -r --arg h "$NOOK_HOST" '.Peer[]? | select(.HostName == $h) |
        if .Online then "online, \(.TailscaleIPs[0])" else "offline" end' | head -n1)
    check tailscale "${peer:-no peer named $NOOK_HOST in this tailnet}"
  else
    check tailscale "not installed"
  fi

  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$NOOK_HOST" true 2>/dev/null; then
    check ssh "ok"
  else
    check ssh "unreachable"
    bad=1
  fi

  check transport "$NOOK_TRANSPORT"

  case $NOOK_TRANSPORT in
    iscsi)
      if command -v iscsiadm >/dev/null; then
        check open-iscsi "installed"
        check initiator "$(sudo grep -h InitiatorName /etc/iscsi/initiatorname.iscsi 2>/dev/null | cut -d= -f2-)"
      else
        check open-iscsi "missing — install open-iscsi"
        bad=1
      fi
      ;;
    nbd)
      if command -v nbd-client >/dev/null; then
        check nbd "installed"
      else
        check nbd "missing — install nbd"
        bad=1
      fi
      ;;
  esac

  if command -v sshfs >/dev/null; then
    check sshfs "installed"
  else
    check sshfs "missing — install sshfs"
    bad=1
  fi

  if command -v docker >/dev/null; then
    if docker context inspect nook >/dev/null 2>&1; then
      check docker "context present"
    else
      check docker "no nook context — run: nook adopt"
    fi
  else
    check docker "not installed"
  fi

  local dev
  dev=$(disk_device || true)
  check drive "${dev:-not attached here}"

  return $bad
}
