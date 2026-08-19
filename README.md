# nook

Your Raspberry Pi, reachable from anywhere, with its disk offered to your
machines two ways: as a folder many of them can share, and as a drive that
mounts like a USB stick — over the network, with no cable.

Built for [Omarchy](https://omarchy.org): a bar widget, menu rows, and a `nook`
command. The Pi half is plain Debian and needs nothing from Omarchy.

## Getting there

On the Pi, once:

```bash
curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash
```

It prints a link and a QR code. Open it on a device already signed in to
Tailscale and the pairing is done — there is no key to generate, copy, or paste
back. `--ssh` goes up with it, so SSH is authenticated by tailnet identity and
no keys are created or authorised anywhere either.

Then on your machine:

```bash
./install.sh    # links the CLI, the mount unit, the menu rows
nook adopt
```

`adopt` reads the Pi's `/etc/nook.conf`, writes an SSH block with a persistent
control socket, points a Docker context at it, enables the mount unit, and adds
`~/nook` to the file manager sidebar.

## Two lanes for the same disk

They are not variations on one idea — they trade different things.

**The shared folder** is `/mnt/nook/files` over SFTP, mounted at `~/nook`. Any
number of machines can hold it at once, containers on the Pi see the same
directory, and Samba can serve it to a phone. This is where bulk files live.

```bash
nook mount
nook push ~/Downloads/big.iso
```

**The drive** is a disk image exported as a block device. Your machine sees a
real `/dev/sdX`, formats it, mounts it, and ejects it. It shows up in the file
manager sidebar with an eject button, because that is what it is.

```bash
nook attach
nook format     # first time only, and it asks
nook eject
```

> **One machine at a time.** A filesystem on a block device assumes it is the
> only thing writing to it. Two machines attaching the same drive read-write
> will corrupt it — both cache metadata and neither knows about the other.
> `nook attach` refuses when someone else holds it, and `nook eject` flushes
> before it disconnects. If you want simultaneous access, that is what the
> shared folder is for.

Which transport carries the drive depends on the kernel. iSCSI is the better
one — discovery, per-initiator ACLs, automatic re-login after a reboot — but
stock Raspberry Pi OS kernels are not built with an iSCSI target, so nook falls
back to NBD, which is entirely userspace on the Pi and works everywhere.
`nook status` says which you got.

> **Neither transport authenticates.** iSCSI ships with no CHAP and NBD has no
> auth at all, so nook binds both to the Tailscale address only. That is the
> security boundary, and it is why the portal is never on `0.0.0.0`. Do not
> move it onto a LAN interface.

## Obsidian

A bare git repo on the Pi, not a sync daemon:

```bash
nook vault init main
```

Then point the Obsidian **Git** plugin at it with commit-and-sync every five
minutes and pull-on-startup. The vault gets history, conflicts are git conflicts
you can actually resolve, and it works offline by construction. Mobile Obsidian
speaks the same remote.

Opening a vault straight off `~/nook` also works, and on a LAN it is fine —
but Obsidian writes its workspace file constantly, so over a slow link the
latency shows.

## Containers

Compose files stay on your machine; the containers run on the Pi. No editing
YAML in nano over SSH.

```bash
nook up ~/stacks/media
nook logs
nook ps
```

Build for the Pi from your laptop's much faster CPU:

```bash
docker buildx build --platform linux/arm64 --push -t ghcr.io/you/thing .
```

`pi/stack/compose.yaml` is a worked example. Nothing in it binds to `0.0.0.0`;
ports go to loopback and `tailscale serve` publishes them on the tailnet with a
real certificate.

## In the bar

The drive glyph is bright when the nook answers and dimmed when it does not,
and turns amber when the CPU goes over the temperature you set. The panel
carries disk use, load, container count, and who is holding the drive, then the
actions that make sense right now — it will not offer **Eject** with nothing
attached.

- **Left click** opens the panel
- **Right click** attaches the drive, or ejects it if it is already here
- **Middle click** mounts the shared folder, or opens it if it is already mounted

The menu behaves the same way: `Super+Space`, then `nook`.

## The boot script

Re-running it is the upgrade path — every module checks its own work first.

```
--name NAME       hostname and Tailscale name (default: nook)
--data PATH       where the external disk is mounted (default: /mnt/nook)
--disk-size SIZE  size of the network drive image (default: 256G)
--format          make a filesystem on a blank external disk
--shares          also run Samba, for phones and non-Linux machines
--usb-gadget      also offer the drive over a USB-C cable
--skip MODULE     skip a module by name, repeatable
```

Nothing is formatted without `--format`: an unpartitioned USB disk is far more
likely to hold somebody's photos than to be blank. The external disk goes into
`/etc/fstab` by UUID with `nofail`, because a headless box that drops to
emergency mode over an unplugged drive is a box you have to go find a monitor
for.

`--usb-gadget` offers the same image over the USB-C port for when there is no
network at all. It exports **read-only** on purpose: the host caches the
filesystem and assumes exclusive ownership, so the image can only ever be live
on one side. The network path stays the one you write through.

## Commands

```
nook adopt [HOST]      pair with a nook that has run the boot script
nook status [--json]   temperature, disk, containers, who holds the drive
nook doctor            check every moving part and say which one is broken

nook mount / umount    the shared folder at ~/nook
nook attach / eject    the drive
nook format            erase the drive and make a filesystem — asks first
nook grow              after a resize, fill the new space
nook disk              what the drive is doing

nook up [DIR]          compose up -d, running on the nook
nook down / ps / logs
nook push SRC [DEST]   rsync into the shared folder
nook pull SRC [DEST]
nook code [PATH]       open the nook in VS Code over SSH
nook ssh
nook vault init [NAME] a bare git repo for an Obsidian vault
```

On the Pi, `nook-target` manages the export and `nook-info` prints the JSON the
widget reads.

## Requirements

**Pi** — Raspberry Pi OS Lite or any Debian, an external USB disk, and a
Tailscale account.

**Your machine** — `sshfs`, `jq`, `rsync`, and `udisks2`; plus `open-iscsi` or
`nbd` depending on which transport the Pi ended up with. `nook doctor` names the
missing one.

## License

MIT
