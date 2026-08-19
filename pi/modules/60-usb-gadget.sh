# shellcheck shell=bash
# 60-usb-gadget — the same disk image over a USB-C cable, for when there is no
# network at all.
#
# Off unless --usb-gadget, and it should stay off unless you want it. The host
# caches the filesystem and assumes nothing else writes to it, so the image can
# only ever be live on one side: exported here, or mounted there, never both.
# nook therefore exports it read-only over USB — the network path stays the one
# you write through.

[[ $NOOK_USB_GADGET == 1 ]] || return 0

IMG=$NOOK_DATA/disk.img
[[ -f $IMG ]] || { warn "no $IMG yet — run 35-disk first"; return 0; }

BOOT=/boot/firmware
[[ -d $BOOT ]] || BOOT=/boot

grep -q '^dtoverlay=dwc2' "$BOOT/config.txt" || {
  printf '\ndtoverlay=dwc2\n' >>"$BOOT/config.txt"
  NOOK_REBOOT_NEEDED=1
}
grep -q 'modules-load=dwc2' "$BOOT/cmdline.txt" || {
  sed -i 's/$/ modules-load=dwc2/' "$BOOT/cmdline.txt"
  NOOK_REBOOT_NEEDED=1
}

cat >/etc/systemd/system/nook-gadget.service <<CONF
[Unit]
Description=Offer the nook disk over USB, read-only
After=$(systemd-escape -p --suffix=mount "$NOOK_DATA")
Requires=$(systemd-escape -p --suffix=mount "$NOOK_DATA")

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/modprobe g_mass_storage file=$IMG ro=1 stall=0 removable=1 idVendor=0x1d6b idProduct=0x0104
ExecStop=/sbin/modprobe -r g_mass_storage

[Install]
WantedBy=multi-user.target
CONF

systemctl daemon-reload
systemctl enable nook-gadget >/dev/null

if [[ ${NOOK_REBOOT_NEEDED:-0} == 1 ]]; then
  warn "USB gadget mode needs a reboot before the port switches roles"
else
  systemctl start nook-gadget
fi
note "plug a USB-C cable into the power port and the nook shows up as a read-only drive"
