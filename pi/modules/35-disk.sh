# 35-disk — the network flash drive.
#
# A disk image on the external drive, exported as a block device so your laptop
# sees a real /dev/sdX it can partition, format, mount and eject. Not a share:
# a filesystem on a block device assumes it is the only one touching it, so
# exactly one machine may attach read-write at a time. The shared lane is
# $NOOK_DATA/files over SFTP and Samba.
#
# Two transports, picked by what the kernel can actually do:
#
#   iSCSI  needs iscsi_target_mod, which stock Raspberry Pi OS kernels do not
#          build. Where it exists it is the better one: discovery, ACLs by
#          initiator name, and automatic re-login after a reboot.
#   NBD    is entirely userspace on this end, so it works on every Pi kernel.
#          Chosen as the fallback for exactly that reason.

IMG=$NOOK_DATA/disk.img

if [[ -z ${NOOK_TS_IP:-} ]]; then
  warn "no tailnet address — skipping the network drive"
  NOOK_TRANSPORT=none
  return 0
fi

# The drive is one big preallocated file. On the system disk that means filling
# the card the box boots from, so without an external disk this half does not
# run at all — the shared folder does, and the box is still worth adopting.
if [[ ${NOOK_HAS_EXTERNAL:-0} != 1 ]]; then
  note "skipped — the network drive needs an external disk"
  NOOK_TRANSPORT=none
  return 0
fi

if [[ ! -f $IMG ]]; then
  # fallocate reserves real blocks. That is deliberate — a sparse image that
  # runs out of room mid-write hands the machine that mounted it an I/O error
  # on a live filesystem — but it means the size has to fit before we start.
  free_bytes=$(df -B1 --output=avail "$NOOK_DATA" | tail -n1 | tr -d ' ')
  want_bytes=$(numfmt --from=iec "${NOOK_DISK_SIZE%B}" 2>/dev/null || echo 0)

  # Half the disk, so the shared folder is not squeezed out by a drive nobody
  # has written to yet.
  if ((want_bytes == 0 || want_bytes > free_bytes / 2)); then
    NOOK_DISK_SIZE=$(numfmt --to=iec --format='%.0f' $((free_bytes / 2)))
    note "sizing the drive at $NOOK_DISK_SIZE — half of what is free on $NOOK_DATA"
  fi

  note "creating $IMG ($NOOK_DISK_SIZE)"
  if ! fallocate -l "$NOOK_DISK_SIZE" "$IMG" 2>/dev/null; then
    # Whatever it managed to reserve before giving up is still on the disk.
    rm -f "$IMG"
    warn "could not reserve $NOOK_DISK_SIZE on $NOOK_DATA — skipping the network drive"
    NOOK_TRANSPORT=none
    return 0
  fi
  chown "$NOOK_USER:$NOOK_USER" "$IMG"
  chmod 600 "$IMG"
fi

install_bin nook-target
install_bin nook-info

if modprobe iscsi_target_mod 2>/dev/null; then
  NOOK_TRANSPORT=iscsi
else
  NOOK_TRANSPORT=nbd
  note "this kernel has no iSCSI target support — using NBD instead"
fi

# ── iSCSI ─────────────────────────────────────────────────────────────────────
if [[ $NOOK_TRANSPORT == iscsi ]]; then
  dpkg -s targetcli-fb >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=300 install -y -qq targetcli-fb
  target=$NOOK_IQN_BASE:$NOOK_NAME

  targetcli /backstores/fileio ls 2>/dev/null | grep -q "o- nook " ||
    targetcli /backstores/fileio create name=nook file_or_dev="$IMG" >/dev/null

  targetcli /iscsi ls 2>/dev/null | grep -qF "$target" ||
    targetcli /iscsi create "$target" >/dev/null

  targetcli "/iscsi/$target/tpg1/luns" ls 2>/dev/null | grep -q "lun0" ||
    targetcli "/iscsi/$target/tpg1/luns" create /backstores/fileio/nook >/dev/null

  # An iSCSI target listens on 0.0.0.0 the moment it is created, and it has no
  # authentication by default. Moving the portal onto the tailnet address is
  # what keeps the disk off every other network this box can see.
  targetcli "/iscsi/$target/tpg1/portals" delete 0.0.0.0 3260 >/dev/null 2>&1 || true
  targetcli "/iscsi/$target/tpg1/portals" ls 2>/dev/null | grep -qF "$NOOK_TS_IP" ||
    targetcli "/iscsi/$target/tpg1/portals" create "$NOOK_TS_IP" 3260 >/dev/null

  # generate_node_acls=0 means an initiator nook has never heard of is refused
  # rather than welcomed. `nook adopt` adds each laptop's IQN through nook-target.
  targetcli "/iscsi/$target/tpg1" set attribute authentication=0 generate_node_acls=0 demo_mode_write_protect=1 >/dev/null

  targetcli saveconfig >/dev/null
  systemctl enable --now rtslib-fb-targetctl >/dev/null 2>&1 ||
    systemctl enable --now targetclid >/dev/null 2>&1 || true
  note "iSCSI target $target on $NOOK_TS_IP:3260"
fi

# ── NBD ───────────────────────────────────────────────────────────────────────
if [[ $NOOK_TRANSPORT == nbd ]]; then
  dpkg -s nbd-server >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=300 install -y -qq nbd-server

  # listenaddr is the security boundary here — NBD has no authentication at all,
  # so the export must never be offered on the LAN interface.
  install -d /etc/nbd-server
  cat >/etc/nbd-server/config <<CONF
[generic]
	user = root
	group = root
	listenaddr = $NOOK_TS_IP
	port = 10809
	allowlist = false

[nook]
	exportname = $IMG
	readonly = false
	flush = true
	fua = true
	splice = true
CONF
  systemctl enable --now nbd-server >/dev/null
  systemctl reload-or-restart nbd-server
  note "NBD export \"nook\" on $NOOK_TS_IP:10809"
fi

printf 'NOOK_TRANSPORT=%s\n' "$NOOK_TRANSPORT" >"$NOOK_STATE/transport"
