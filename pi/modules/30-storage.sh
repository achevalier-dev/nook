# 30-storage — mount the external disk at $NOOK_DATA, by UUID, and lay out the
# directories everything else expects.
#
# Never formats on its own. An unpartitioned USB disk is far more likely to hold
# somebody's photos than to be blank, so making a filesystem needs --format.

mkdir -p "$NOOK_DATA"

disk=$(lsblk -dpno NAME,TRAN 2>/dev/null | awk '$2 == "usb" { print $1; exit }' || true)

if [[ -z ${disk:-} ]]; then
  warn "no USB disk found — $NOOK_DATA will live on the SD card, which is slow and wears out"
else
  part=$(lsblk -pnro NAME,TYPE "$disk" | awk '$2 == "part" { print $1; exit }' || true)

  if [[ -z ${part:-} ]] || ! blkid "$part" >/dev/null 2>&1; then
    if [[ $NOOK_FORMAT != 1 ]]; then
      warn "$disk has no filesystem nook recognises; re-run with --format to erase and use it"
      warn "skipping external storage for now"
      return 0
    fi
    note "erasing $disk and making one ext4 filesystem on it"
    wipefs -a "$disk" >/dev/null
    sgdisk -Z "$disk" >/dev/null
    sgdisk -n1:0:0 -t1:8300 -c1:nook "$disk" >/dev/null
    partprobe "$disk"
    # udev needs a moment to publish the new node before mkfs can open it.
    udevadm settle
    part=$(lsblk -pnro NAME,TYPE "$disk" | awk '$2 == "part" { print $1; exit }')
    mkfs.ext4 -q -L nook "$part"
  fi

  uuid=$(blkid -s UUID -o value "$part")
  # nofail and a short device timeout are not optional on a headless box: without
  # them a disk you unplugged leaves the Pi sitting in emergency mode forever,
  # and there is no screen attached to tell you so.
  entry="UUID=$uuid $NOOK_DATA ext4 defaults,noatime,nofail,x-systemd.device-timeout=10 0 2"
  if grep -q "UUID=$uuid" /etc/fstab; then
    sed -i "s|^UUID=$uuid.*|$entry|" /etc/fstab
  else
    printf '%s\n' "$entry" >>/etc/fstab
  fi
  systemctl daemon-reload
  mountpoint -q "$NOOK_DATA" || mount "$NOOK_DATA"
  note "$part mounted at $NOOK_DATA ($(df -h --output=avail "$NOOK_DATA" | tail -n1 | tr -d ' ') free)"
fi

# files/  is the shared lane: the FUSE mount and Samba both see it, and so do
#         containers. Many readers at once, no block device involved.
# vaults/ holds bare git repos — the Obsidian sync path.
# disk.img is the private lane: one machine attaches it at a time.
install -d -o "$NOOK_USER" -g "$NOOK_USER" "$NOOK_DATA/files" "$NOOK_DATA/vaults" "$NOOK_DATA/docker"
chown "$NOOK_USER:$NOOK_USER" "$NOOK_DATA"
