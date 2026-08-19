# The network drive

A sparse disk image on the Pi's external disk, exported as a block device so
your machine sees a real disk it can partition, format, mount and eject.

## Which transport

Decided by `35-disk` at boot time, not configurable by preference:

- **iSCSI** where `modprobe iscsi_target_mod` succeeds. Better: discovery,
  per-initiator ACLs, automatic re-login after a reboot.
- **NBD** otherwise. Stock Raspberry Pi OS kernels are not built with an iSCSI
  target, and `nbd-server` is entirely userspace, so it works everywhere.

`nook status` and `/etc/nook.conf` both name the one in use. The CLI branches on
it internally; you should not have to.

## Everyday use

```bash
nook attach     # bring it up here
nook eject      # flush, unmount, disconnect
nook disk       # transport, size, who is attached
```

`attach` asks the Pi who holds the drive before doing anything, and refuses if
that is not nobody. `eject` unmounts and `sync`s before tearing the transport
down — pulling a device out from under a dirty filesystem is how images rot.

On iSCSI, `attach` also sets `node.startup=automatic` so the drive comes back
after a reboot, and `eject` sets it back to `manual`. That is deliberate: the
drive should not silently re-attach on a machine you ejected it from, because
some other machine may have taken it.

## First use

A fresh image has no filesystem. `nook attach` says so and stops.

```bash
nook format     # asks you to type the label; erases the drive
```

No partition table on purpose — one filesystem filling the device means no
`partprobe` round trip over the network, and `nook grow` stays one line.
`tune2fs -m 0` follows, because ext4's 5% root reserve is pointless on a data
disk and costs 12GB out of 256.

## Growing it

Two halves, in order, and nothing may be attached:

```bash
nook eject
nook ssh sudo nook-target resize 512G   # the image
nook attach
nook grow                                # the filesystem inside it
```

`nook-target resize` refuses while anyone is attached, refuses to shrink, and on
iSCSI rebuilds the backstore — LIO reads the backing file size once, at
creation, so the export has to be rebuilt for the new size to be visible.

## When it goes wrong

**"another machine has the disk attached"** — it is telling the truth.
`nook ssh nook-target info` lists the addresses holding it. Eject there. If a
machine died holding it, the socket clears when its TCP connection times out, or
immediately with `nook ssh sudo systemctl restart nbd-server` (NBD) — which
severs the export, so make sure nothing is genuinely writing.

**Device never appears** — `nook doctor` first. On iSCSI the usual cause is a
missing ACL for this machine's initiator name; `nook adopt` adds it.

**Filesystem errors after a link drop** — `nook eject`, then
`sudo fsck -f <device>` on the next attach before mounting. NBD is attached with
`-persist` precisely so a late packet does not become an I/O error, but a long
outage still can.

## USB gadget mode

`--usb-gadget` offers the *same image* over the USB-C port. It exports
**read-only**, and that is not a limitation to work around: the host caches the
filesystem and assumes exclusive ownership, so the image can only ever be live
on one side. The network path stays the one you write through.
