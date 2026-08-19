---
name: nook
description: >
  REQUIRED when working with a nook — a Raspberry Pi set up by the nook boot
  script and driven from another machine by the `nook` CLI. Use for anything
  involving the shared folder at ~/nook, the network drive (iSCSI or NBD), the
  Pi's external disk, containers running on the Pi through the `nook` Docker
  context, Obsidian vaults kept as bare git repos on the Pi, or the Omarchy bar
  widget and menu rows that front all of it. Triggers: nook, nook attach, nook
  mount, nook adopt, network drive, /mnt/nook, nook-target, nook-info,
  /etc/nook.conf, "my pi", raspberry pi drive, iscsi, nbd, tailscale pi.
  Excludes generic Raspberry Pi work on a machine that has never run the nook
  boot script.
---

# nook Skill

A nook is any box that has run `pi/boot.sh` from
[nook](https://github.com/achevalier-dev/nook) — a Raspberry Pi, a mini PC, an
old ThinkCentre. It is reachable over Tailscale, its external disk is at
`/mnt/nook`, and it offers that disk to your machines two different ways.

**There can be several.** Each adopted box gets its own directory under
`~/.nook`, and every command talks to whichever one is selected:

```bash
nook list                # every nook here, default marked *
nook use thinkcentre     # change the default
NOOK=pi nook status      # one command against another one, default unchanged
nook status --all        # every box, one after another
nook doctor --all
```

Before answering anything about "the nook", check which one is selected —
`nook list` is one line and costs nothing. Per-box values are derived, never
shared: the mount is `~/nook/<name>`, the drive label is the name uppercased,
the Docker context is `nook-<name>`, and NBD devices are allocated per nook and
recorded in `~/.nook/<name>/nbd`.

Everything here is driven by the `nook` CLI on the machine you are sitting at.
Prefer it over `ssh`, `iscsiadm`, `nbd-client`, `sshfs`, and `docker --context`
run by hand: the CLI carries the guards, and the guards are the point.

## The Two Lanes

This is the model everything else depends on. Get it wrong and you corrupt a
filesystem.

| | Shared folder | Network drive |
|---|---|---|
| What | `/mnt/nook/files` over SFTP | a disk image as a real block device |
| Where | `~/nook` on your machine | `/dev/sdX` or `/dev/nbd0`, mounted by udisks |
| Readers | **many machines at once** | **exactly one machine at a time** |
| Commands | `nook mount`, `nook umount`, `nook push` | `nook attach`, `nook eject`, `nook format` |
| Use it for | bulk files, anything containers on the Pi also read | a drive you want to behave like a USB stick |

A filesystem on a block device assumes it owns the device. Two machines
attaching the same drive read-write **will** corrupt it — both cache metadata,
neither knows about the other, and the damage surfaces long after the mistake.

## Topic Guides

Read the matching guide before starting:

- [`setup.md`](setup.md) — the boot script, its modules, adopting a nook, re-running safely
- [`drive.md`](drive.md) — the network drive: transports, attach/eject/format, resizing, recovery
- [`containers.md`](containers.md) — the Docker context, compose from your machine, publishing ports
- [`vaults.md`](vaults.md) — Obsidian vaults as bare git repos
- [`troubleshooting.md`](troubleshooting.md) — what `nook doctor` checks and what each failure means

## Critical Safety Rules

**Never attach the drive while another machine holds it.** `nook attach` asks
the Pi first and refuses. If you are reaching for `iscsiadm --login` or
`nbd-client` directly, you are bypassing that check — do not.

**Never `mkfs` a device you have not confirmed is the nook drive.** `nook
format` resolves the device itself and makes the user type the label. A
hand-written `mkfs.ext4 /dev/sdb` on a machine with a real USB stick plugged in
is how someone loses the wrong disk.

**Never move the iSCSI portal or the NBD `listenaddr` off the Tailscale
address.** Neither transport authenticates — iSCSI ships without CHAP and NBD
has no auth at all. The tailnet binding is the entire security boundary. The
same goes for the Samba block, which is bound to `tailscale0`.

**Never mount `disk.img` on the Pi while it is exported.** Same single-writer
rule, from the other side.

**Two boxes must never share a mount point, a drive label, a Docker context or
an NBD device.** All four are derived from the nook's name in `load_config`, and
`test/nooks_test.sh` exists to keep them apart. A collision looks like the wrong
machine answering, which is a miserable thing to debug.

**`/etc/nook.conf` is generated.** The boot script writes it last, from the
choices that actually took effect. Editing it by hand makes the CLI's view and
the Pi's reality disagree. Re-run the boot script with different flags instead.

**Do not remove `nofail` from the `/etc/fstab` entry.** A headless Pi that drops
to emergency mode over an unplugged USB disk needs a monitor to recover.

## Command Discovery

```bash
nook                 # the full command list
nook status          # temperature, disk, containers, who holds the drive
nook status --json   # the same, machine-readable — this is what the widget polls
nook doctor          # check every moving part and name the broken one
nook disk            # the drive: transport, size, who is attached
nook disk --local    # the same without the SSH round trip
nook help --all      # every command, including the rare ones
```

The CLI on the machine you are sitting at updates itself daily
(`nook update --auto` / `--no-auto`, a user timer, fast-forward only). Before
concluding that a command or a menu row is broken, check `nook doctor`'s `cli`
line: a copy that is behind is missing commands the box already has, which looks
exactly like a bug.

`NOOK_HOME` moves the config directory, which is how the tests and any
throwaway experiment stay out of the real one:

```bash
NOOK_HOME=/tmp/nook-test nook status
```

`nook status --json` shape:

```json
{"name":"nook","uptime":"3 days","temp":48.2,"load":0.14,
 "disk":{"size":0,"used":0,"avail":0},
 "containers":4,"transport":"nbd","attached":0}
```

`attached` counts established connections to the export port. It cannot name
who — the box only sees sockets. `nook attach` prints the addresses.

## Where Things Live

On the machine you use:

| Path | What |
|---|---|
| `~/.nook/<name>/config` | written by `nook adopt`; host, transport, target IQN, paths |
| `~/.nook/<name>/nbd` | which NBD device this nook was given |
| `~/.nook/default` | one line: the nook commands use when nothing says otherwise |
| `~/.config/systemd/user/nook-mount@.service` | templated sshfs unit; one instance per nook |
| `~/.ssh/config` | one marked `# >>> nook` block covering every nook |
| `/etc/udev/rules.d/99-nook.rules` | makes the drive show as removable, not a system disk |
| `~/nook/<name>` | the shared folder mount point for that nook |

On the Pi:

| Path | What |
|---|---|
| `/etc/nook.conf` | generated; name, data path, transport, target IQN, image path |
| `/mnt/nook/files` | the shared lane |
| `/mnt/nook/disk.img` | the drive, sparse |
| `/mnt/nook/vaults` | bare git repos |
| `/var/lib/nook` | boot-script state and cached modules |
| `/usr/local/bin/nook-target` | ACLs, export info, resize |
| `/usr/local/bin/nook-info` | the JSON `nook status` reads |

## Verifying a Change

Every change to a nook has a cheap check. Use it — do not report success from a
command that merely exited zero.

```bash
nook doctor                       # after anything on the client side
nook status                       # after anything on the Pi
nook disk                         # after attach, eject, format, resize
findmnt ~/nook                    # after mount
lsblk -f $(nook disk --local | awk '/^disk / && $2 != "not" {print $2}')
nook ssh systemctl status nbd-server      # or rtslib-fb-targetctl for iSCSI
```

## The Omarchy Front End

The bar widget and the menu rows live in a separate repository,
[omarchy-nook](https://github.com/achevalier-dev/omarchy-nook). They are a thin
layer over this CLI: the widget polls `nook status --json` and `nook disk
--local`, and every menu row runs a `nook` command. A problem with what they
*show* is almost always a problem with what the CLI *says* — check the CLI
first.

## Out of Scope

Developing Omarchy itself, or a Raspberry Pi that has never run the nook boot
script. For editing Hyprland or `shell.json`, use the `omarchy` skill.
