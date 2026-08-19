# shellcheck shell=bash
# nook status — one screen of the nook's own numbers plus what this machine
# holds. nook doctor — every moving part, named individually.
#
# Needs lib/drive.sh sourced alongside it for disk_device.

# shellcheck disable=SC2120  # bin/nook passes --json and --all through
cmd_status() {
  # Every nook, one after another. A subshell per box so the globals load_config
  # sets for one do not leak into the next.
  if [[ ${1:-} == --all ]]; then
    local name first=1
    while read -r name; do
      [[ -n $name ]] || continue
      ((first)) || echo
      first=0
      (
        NOOK=$name
        cmd_status
      ) || true
    done < <(nooks)
    return 0
  fi

  need jq
  load_config

  local json
  json=$(remote nook-info 2>/dev/null) || die "$NOOK_HOST is not answering"

  if [[ ${1:-} == --json ]]; then
    printf '%s\n' "$json"
    return 0
  fi

  jq -r --arg alias "$NOOK" '
    "nook       \($alias)  ·  up \(.uptime)",
    "load       \(.load)   temp \(.temp)°C",
    "disk       \((.disk.used/1073741824)|floor)G used of \((.disk.size/1073741824)|floor)G  ·  \((.disk.avail/1073741824)|floor)G free",
    "containers \(.containers) running",
    "drive      \(if .transport == "none" then "none on this box" else "\(.transport), \(if .attached > 0 then "attached by \(.attached)" else "free" end)" end)"
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

# What this machine's own copy of nook is, and whether it is current. No fetch:
# the answer comes from whatever the last pull or `nook upgrade` already knew, so
# `nook doctor` stays a local command that works on a dead network.
cli_state() {
  command -v git >/dev/null && [[ -d $ROOT/.git ]] || { echo "not a git checkout"; return 0; }

  local head behind dirty=""
  head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  [[ -n $(git -C "$ROOT" status --porcelain 2>/dev/null) ]] && dirty=", modified here"
  behind=$(git -C "$ROOT" rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

  if ((behind > 0)); then
    echo "$head, $behind commits behind$dirty — run: nook update"
  else
    echo "$head, updates $(update_timer_state)$dirty"
  fi
}

# Prints every check even when an early one fails: "ssh is down" and "sshfs is
# missing" are different problems and the second is worth knowing about now.
# shellcheck disable=SC2120  # bin/nook passes --all through
cmd_doctor() {
  if [[ ${1:-} == --all ]]; then
    local name first=1
    local worst=0
    while read -r name; do
      [[ -n $name ]] || continue
      ((first)) || echo
      first=0
      echo "── $name"
      ( NOOK=$name; cmd_doctor ) || worst=1
    done < <(nooks)
    return $worst
  fi

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
    # The context is named after the nook, not "nook" — two boxes would collide.
    if docker context inspect "$NOOK_CONTEXT" >/dev/null 2>&1; then
      check docker "context $NOOK_CONTEXT"
    else
      check docker "no $NOOK_CONTEXT context — run: nook adopt"
    fi
  else
    check docker "not installed"
  fi

  local dev
  dev=$(disk_device || true)
  check drive "${dev:-not attached here}"

  # The failure this catches is not a broken box: it is a machine whose own copy
  # of nook is old enough that commands the box supports are missing here, which
  # reads as features that do not work rather than as a version.
  check cli "$(cli_state)"

  return $bad
}
