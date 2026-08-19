# shellcheck shell=bash
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

# An external disk is better — more room, no wear on the card the box boots
# from — but it is not required. What is required is that the image fits with
# room to spare, because fallocate reserves real blocks and a full root
# filesystem takes the whole box down.
if [[ ! -f $IMG ]]; then
  free_bytes=$(df -B1 --output=avail "$NOOK_DATA" | tail -n1 | tr -d ' ')
  want_bytes=$(numfmt --from=iec "${NOOK_DISK_SIZE%B}" 2>/dev/null || echo 0)

  if [[ ${NOOK_HAS_EXTERNAL:-0} == 1 ]]; then
    # A disk plugged in for this is allowed to be mostly this.
    reserve=$((2 * 1024 ** 3))
    share=80
  else
    # The system disk also holds the OS, the logs, and every container image
    # 40-docker will pull. Leave it room to breathe.
    reserve=$((10 * 1024 ** 3))
    share=50
  fi

  usable=$((free_bytes * share / 100))
  ((usable > free_bytes - reserve)) && usable=$((free_bytes - reserve))

  # Below a few gigabytes it is not a drive worth having, and the box is still
  # a perfectly good nook without one.
  if ((usable < 4 * 1024 ** 3)); then
    note "skipped — only $(numfmt --to=iec --format='%.0f' "$free_bytes") free on $NOOK_DATA"
    note "plug in an external disk, or free some space, and run this again"
    NOOK_TRANSPORT=none
    return 0
  fi

  if ((want_bytes == 0 || want_bytes > usable)); then
    NOOK_DISK_SIZE=$(numfmt --to=iec --format='%.0f' "$usable")
    note "sizing the drive at $NOOK_DISK_SIZE to fit $NOOK_DATA"
  fi

  note "creating $IMG ($NOOK_DISK_SIZE)"
  # fallocate reserves real blocks rather than making a sparse file. That is
  # deliberate: a sparse image that runs out of room mid-write hands the machine
  # that mounted it an I/O error on a live filesystem.
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
