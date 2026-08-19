# nook

A Raspberry Pi you reach from anywhere, offering its disk to your machines two
ways: as a folder many of them can share, and as a drive that mounts like a USB
stick — over the network, with no cable.

Bash, `ssh`, `rsync` and the kernel's own block-device client. No daemon, no
database, no agent running on your laptop.

The bar widget and menu rows for [Omarchy](https://omarchy.org) are a separate
repository, [omarchy-nook](https://github.com/achevalier-dev/omarchy-nook). This
one is the CLI and the Pi.

![adopting a nook, mounting it, attaching the drive, and being refused](demo/nook.gif)

*Staged: there is no Raspberry Pi in that recording. `demo/fake-nook` replaces
the SSH connection, the block device and the mount table, and nothing else — so
every line on screen is printed by the same `cmd_` functions a real nook runs.
`demo/record.sh` captures what they print and `demo/render.py` draws it.*

## Getting there

On the Pi, once:

```bash
curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash
```

It prints a link and a QR code. Open it on a device already signed in to
Tailscale and the pairing is done — there is no key to generate, copy, or paste
back. `--ssh` goes up with it, so SSH authenticates by tailnet identity and no
keys are created or authorised anywhere either.

Then on your machine:

```bash
./install.sh
nook adopt
```

Or do both from your machine, if the Pi already has SSH:

```bash
nook boot raspberrypi.local -- --format
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
> `nook attach` asks the Pi who holds it and refuses; `nook eject` flushes
> before it disconnects. If you want simultaneous access, that is what the
> shared folder is for.

Which transport carries the drive depends on the kernel. iSCSI is the better
one — discovery, per-initiator ACLs, automatic re-login after a reboot — but
stock Raspberry Pi OS kernels are not built with an iSCSI target, so nook falls
back to NBD, which is entirely userspace on the Pi and works everywhere.
`nook status` says which you got.

> **Neither transport authenticates.** iSCSI ships with no CHAP and NBD has no
> auth at all, so nook binds both to the Tailscale address only. That is the
> security boundary, and it is why the portal is never on `0.0.0.0`.

## Obsidian

A bare git repo on the Pi, not a sync daemon:

```bash
nook vault init main
```

Then point the Obsidian **Git** plugin at it with commit-and-sync every five
minutes and pull-on-startup. The vault gets history, conflicts are git conflicts
you can actually resolve, and it works offline by construction. Mobile Obsidian
speaks the same remote.

## Containers

Compose files stay on your machine; the containers run on the Pi. No editing
YAML in nano over SSH.

```bash
nook up ~/stacks/media
nook logs
nook ps
```

Build for the Pi on your laptop's much faster CPU:

```bash
docker buildx build --platform linux/arm64 --push -t ghcr.io/you/thing .
```

`pi/stack/compose.yaml` is a worked example. Nothing in it binds to `0.0.0.0`;
ports go to loopback and `tailscale serve` publishes them on the tailnet with a
real certificate.

## Commands

```
nook adopt [host]      pair with a nook that has run the boot script
nook boot <host>       run the boot script on a Pi over SSH, then adopt it
nook status [--json]   temperature, disk, containers, who holds the drive
nook doctor            check every moving part and name the broken one

nook mount / umount    the shared folder at ~/nook
nook push / pull       rsync in and out of it
nook code [path]       open the nook in VS Code over SSH

nook attach / eject    the drive
nook format            erase the drive and make a filesystem — asks first
nook grow              after a resize, fill the new space
nook disk [--local]    what the drive is doing

nook up / down / ps / logs
nook vault init [name] a bare git repo for an Obsidian vault
nook ssh
nook help --all        every command
```

`NOOK_HOME` moves the config directory, which is how a throwaway experiment
stays out of the real one.

On the Pi, `nook-target` manages the export and `nook-info` prints the JSON
`nook status` reads.

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
on one side.

## Claude Code

`install.sh` links `skills/nook` into `~/.claude/skills/`. Claude then knows the
two lanes, the single-writer rule, which transport your Pi ended up with, and
what `nook doctor` is telling you — and reaches for the CLI rather than raw
`iscsiadm` and `nbd-client`.

```
skills/nook/
├── SKILL.md            the model, the safety rules, where everything lives
├── setup.md            boot script, modules, adopting
├── drive.md            transports, attach/eject/format, resizing, recovery
├── containers.md       the Docker context, compose, publishing ports
├── vaults.md           Obsidian as bare git repos
└── troubleshooting.md  symptom to cause
```

`/nook` is a slash command that runs `status` and `doctor` and reads the result.

## Structure

```
bin/nook           dispatcher
lib/<topic>.sh     one file per area, exporting cmd_<name> functions
pi/boot.sh         the one-liner, and pi/modules/ the steps it sources
pi/bin/            helpers installed onto the Pi
skills/nook/       the Claude Code skill
systemd/ udev/     the mount unit and the rule that makes the drive removable
```

```bash
./script/check     # syntax, shellcheck, json, four behaviour tests — no Pi needed
./demo/record.sh && ./demo/render.py   # rebuild the recording above
```

`demo/fake-nook` is worth knowing about beyond the GIF: it runs the real
subcommands with only the Pi-facing calls replaced, which makes it the fastest
way to see what a change prints without a nook in front of you.

See [AGENTS.md](AGENTS.md) for the shell rules, and
[CONTRIBUTING.md](CONTRIBUTING.md) before a pull request.

## Requirements

**Pi** — Raspberry Pi OS Lite or any Debian, an external USB disk, and a
Tailscale account.

**Your machine** — Linux with `ssh`, `sshfs`, `jq`, `rsync` and `udisks2`, plus
`open-iscsi` or `nbd` depending on which transport the Pi ended up with.
`nook doctor` names the missing one.

## License

MIT
