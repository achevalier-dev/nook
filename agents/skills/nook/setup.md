# Setting up and adopting a nook

## The boot script

One command on the Pi, over SSH or on a keyboard attached to it:

```bash
curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash
```

It re-execs itself under `sudo -E`, refuses anything that is not Debian, then
sources its modules in order. **Re-running it is the upgrade path** — every
module checks its own work first, so a second run is cheap and safe.

```
--name NAME       hostname and Tailscale name (default: nook)
--data PATH       where the external disk is mounted (default: /mnt/nook)
--disk-size SIZE  size of the drive image (default: 256G)
--format          make a filesystem on a blank external disk
--shares          also run Samba
--usb-gadget      also offer the drive over a USB-C cable, read-only
--skip MODULE     skip a module by name, repeatable
```

## The modules

| Module | Does | Notable |
|---|---|---|
| `10-base` | hostname, packages, unattended security upgrades, NTP | rewrites the `127.0.1.1` line so `sudo` stops warning |
| `20-tailscale` | `tailscale up --ssh --qr` | blocks until the box is really on the tailnet |
| `30-storage` | external disk into fstab by UUID, directory layout | never formats without `--format` |
| `35-disk` | the drive image and its export | picks iSCSI or NBD by what the kernel supports |
| `40-docker` | Docker, data-root on the external disk | adds the user to the `docker` group |
| `50-shares` | Samba on `tailscale0` | only with `--shares` |
| `60-usb-gadget` | `g_mass_storage`, read-only | only with `--usb-gadget`; needs a reboot |

Modules are **sourced**, not executed. A module that wants to give up early
uses `return`, never `exit` — an `exit` takes the whole run down mid-way.
`set -euo pipefail` is already in effect, so a bare `cond && action` guard that
turns out false will kill the run; write `if` blocks.

A checkout on disk wins over the fetched copy, which is what makes
`git clone && sudo pi/boot.sh` a working development loop.

## Pairing

No auth key anywhere. `tailscale up` prints a link and a QR code; opening it on
a device already signed in to Tailscale is the whole pairing step. A key on a
command line lands in shell history and `/proc/*/cmdline` and buys nothing.

`--ssh` goes up with it, so SSH authenticates by tailnet identity. Nothing
generates, copies, or authorises an SSH key — if you find yourself running
`ssh-copy-id`, something has gone wrong upstream of that.

## Adopting from your machine

```bash
./install.sh    # links the CLI, mount unit, udev rule, menu rows, this skill
nook adopt      # or: nook adopt <hostname>
```

`adopt` is idempotent and does six things:

1. Proves SSH works, then reads the Pi's `/etc/nook.conf`
2. Writes `~/.config/nook/config` from it
3. Replaces the marked `# >>> nook` block in `~/.ssh/config` — on top, because
   Host blocks are first-match-wins and a wildcard further up would swallow it
4. On iSCSI only: sets this machine's InitiatorName and asks the Pi to allow it
5. Creates or updates the `nook` Docker context
6. Enables the mount unit and adds `~/nook` to the GTK bookmarks

Re-run it after changing the Pi's transport, hostname, or data path.

## Adding a second machine

Run `install.sh` and `nook adopt` there too. On iSCSI each machine gets its own
initiator name and its own ACL entry; on NBD there are no ACLs and the tailnet
is the boundary. Either way the drive is still one-at-a-time — the second
machine can hold the shared folder simultaneously, not the drive.
