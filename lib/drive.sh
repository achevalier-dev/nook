# shellcheck shell=bash
# The private lane: a disk image on the nook, exported as a block device so this
# machine sees a real disk it can format, mount and eject.
#
# A filesystem on a block device assumes it owns the device. Two machines
# attaching the same drive read-write will corrupt it — both cache metadata and
# neither knows about the other. Every guard below exists for that one reason.

NOOK_BOOT_HINT=${NOOK_BOOT_URL:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh}

# NBD hands out numbered devices from one pool shared by every export on the
# machine, so a second nook must not land on the first one's device. The choice
# is recorded per nook, because nothing in /dev says which box a device belongs
# to once it is connected.
nbd_size() { cat "/sys/block/$(basename "$1")/size" 2>/dev/null || echo 0; }

allocate_nbd() {
  local i dev
  # A device we picked before and nobody is using is the one to pick again —
  # it keeps /dev stable across attaches for anyone watching.
  if [[ -n ${NBD_DEV:-} && $(nbd_size "$NBD_DEV") == 0 ]]; then
    echo "$NBD_DEV"
    return 0
  fi
  for i in $(seq 0 15); do
    dev=/dev/nbd$i
    [[ -e /sys/block/nbd$i ]] || continue
    [[ $(nbd_size "$dev") == 0 ]] || continue
    echo "$dev"
    return 0
  done
  die "every nbd device is in use — eject another nook's drive first"
}

# Which device the drive arrived as, or nothing. Asked rather than remembered:
# on iSCSI the kernel picks the letter and it moves between attaches.
disk_device() {
  if [[ $NOOK_TRANSPORT == nbd ]]; then
    # An idle /dev/nbd0 exists but reports zero size, so its presence proves
    # nothing — the size is what says a connection is live.
    [[ -n ${NBD_DEV:-} && -b $NBD_DEV ]] || return 1
    [[ $(nbd_size "$NBD_DEV") -gt 0 ]] || return 1
    echo "$NBD_DEV"
    return 0
  fi
  local path
  for path in /dev/disk/by-path/*iscsi*"${NOOK_TARGET_IQN##*:}"*-lun-0; do
    if [[ -e $path ]]; then
      readlink -f "$path"
      return 0
    fi
  done
  return 1
}

wait_for_disk() {
  local tries=0
  until disk_device >/dev/null; do
    ((tries++ < 40)) || die "the drive never appeared — try: nook doctor"
    sleep 0.25
  done
  disk_device
}

# Who the nook can see holding the export. It counts sockets, not names, so this
# is the only place the addresses are available.
drive_holders() {
  remote nook-target info | awk '/^attached/ { $1 = ""; print }' | xargs || true
}

cmd_attach() {
  load_config
  if [[ $NOOK_TRANSPORT == none ]]; then
    die "$NOOK has no drive — it had no external disk when it was set up.
  Plug one in and run the boot script on it again:
      nook ssh
      curl -fsSL $NOOK_BOOT_HINT | bash -s -- --format
  The shared folder works without one: nook mount"
  fi

  local dev
  dev=$(disk_device || true)
  if [[ -n $dev ]]; then
    echo "already attached at $dev"
    cmd_disk --local
    return 0
  fi

  # Asking first is cheaper than recovering a filesystem two machines wrote to.
  local holders
  holders=$(drive_holders)
  if [[ -n $holders && $holders != none ]]; then
    die "another machine has the drive attached ($holders) — eject it there first"
  fi

  if [[ $NOOK_TRANSPORT == nbd ]]; then
    need nbd-client "nbd"
    sudo modprobe nbd
    NBD_DEV=$(allocate_nbd)
    printf '%s\n' "$NBD_DEV" >"$NOOK_DIR/nbd"
    # -persist keeps the device alive across a suspend or a flaky link instead
    # of handing the filesystem an I/O error the moment a packet is late.
    sudo nbd-client "$NOOK_HOST" 10809 "$NBD_DEV" -name nook -persist
  else
    need iscsiadm "open-iscsi"
    sudo iscsiadm -m discovery -t st -p "$NOOK_HOST" >/dev/null
    sudo iscsiadm -m node -T "$NOOK_TARGET_IQN" -p "$NOOK_HOST" --login >/dev/null
    # Comes back after a reboot — but only on the machine that attached it, and
    # `nook eject` puts this back to manual so an ejected drive stays ejected.
    sudo iscsiadm -m node -T "$NOOK_TARGET_IQN" -p "$NOOK_HOST" \
      -o update -n node.startup -v automatic >/dev/null
  fi

  dev=$(wait_for_disk)

  if ! sudo blkid "$dev" >/dev/null 2>&1; then
    notify "attached at $dev — no filesystem yet, run: nook format"
    return 0
  fi

  udisksctl mount -b "$dev" >/dev/null 2>&1 || drive_mount_fallback "$dev"
  notify "attached at $(mounted_at "$dev")"
}

# udisks files a network block device under system disks on a machine without
# the udev rule, and refuses to mount it. Somewhere under /run/media keeps the
# path predictable and out of /mnt, which belongs to the user.
drive_mount_fallback() {
  local target="/run/media/$USER/$NOOK_LABEL"
  sudo mkdir -p "$target"
  sudo mount "$1" "$target"
}

cmd_eject() {
  load_config
  local dev target
  dev=$(disk_device || true)
  [[ -n $dev ]] || { echo "nothing attached"; return 0; }

  # Unmount before tearing down the transport so the filesystem gets to flush.
  # Pulling the device out from under a dirty filesystem is how images rot.
  target=$(mounted_at "$dev")
  if [[ -n $target ]]; then
    udisksctl unmount -b "$dev" >/dev/null 2>&1 || sudo umount "$dev"
  fi
  sync

  if [[ $NOOK_TRANSPORT == nbd ]]; then
    sudo nbd-client -d "$NBD_DEV"
  else
    sudo iscsiadm -m node -T "$NOOK_TARGET_IQN" -p "$NOOK_HOST" \
      -o update -n node.startup -v manual >/dev/null
    sudo iscsiadm -m node -T "$NOOK_TARGET_IQN" -p "$NOOK_HOST" --logout >/dev/null
  fi
  notify "ejected"
}

cmd_format() {
  load_config
  local dev target answer
  dev=$(disk_device || true)
  [[ -n $dev ]] || die "attach the drive first: nook attach"

  cat <<EOF

  This erases everything on the nook drive at $dev.
  It is $NOOK's drive, not the shared $NOOK_DATA/files folder, and not the
  box's own system disk — but whatever is on it now is gone for good.

EOF
  # The device is resolved for you and the label has to be typed: a hand-written
  # mkfs on a machine with a real USB stick plugged in is how someone loses the
  # wrong disk.
  read -rp "  Type the label \"$NOOK_LABEL\" to confirm: " answer
  [[ $answer == "$NOOK_LABEL" ]] || die "not confirmed"

  target=$(mounted_at "$dev")
  if [[ -n $target ]]; then
    udisksctl unmount -b "$dev" >/dev/null 2>&1 || sudo umount "$dev"
  fi

  # No partition table on purpose: one filesystem filling the device means no
  # partprobe round trip over the network, and `nook grow` stays one line.
  sudo mkfs.ext4 -q -L "$NOOK_LABEL" "$dev"
  # ext4 reserves 5% for root, which is pointless on a data disk and costs 12GB
  # out of 256.
  sudo tune2fs -m 0 "$dev" >/dev/null
  udisksctl mount -b "$dev" >/dev/null 2>&1 || drive_mount_fallback "$dev"
  notify "formatted and mounted at $(mounted_at "$dev")"
}

cmd_grow() {
  load_config
  local dev
  dev=$(disk_device || true)
  [[ -n $dev ]] || die "attach the drive first: nook attach"
  sudo resize2fs "$dev"
  echo "the filesystem now fills the device"
}

cmd_disk() {
  load_config
  local dev at
  dev=$(disk_device || true)
  if [[ -z $dev ]]; then
    echo "disk       not attached ($NOOK_TRANSPORT)"
  else
    at=$(mounted_at "$dev")
    echo "disk       $dev via $NOOK_TRANSPORT"
    echo "mounted    ${at:-no}"
  fi
  # --local answers from this machine alone. The bar widget polls this, and an
  # extra SSH round trip per poll is what makes a widget feel heavy.
  if [[ ${1:-} != --local ]]; then
    remote nook-target info
  fi
}
