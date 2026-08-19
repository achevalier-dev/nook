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
[[ -n ${NOOK_TS_IP:-} ]] || { warn "no tailnet address — skipping the network disk"; return 0; }

if [[ ! -f $IMG ]]; then
  note "creating $IMG ($NOOK_DISK_SIZE, sparse — it costs nothing until written)"
  fallocate -l "$NOOK_DISK_SIZE" "$IMG" || truncate -s "$NOOK_DISK_SIZE" "$IMG"
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
  dpkg -s targetcli-fb >/dev/null 2>&1 || apt-get install -y -qq targetcli-fb
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
  dpkg -s nbd-server >/dev/null 2>&1 || apt-get install -y -qq nbd-server

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
