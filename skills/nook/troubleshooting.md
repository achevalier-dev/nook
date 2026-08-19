# Troubleshooting

Start here, always:

```bash
nook doctor
```

It checks, in order: the Tailscale peer, SSH, the transport, the client package
for that transport (`open-iscsi` or `nbd`), the iSCSI initiator name, `sshfs`,
and the Docker context. It exits non-zero when something is broken.

## By symptom

**`no nook adopted here`** — nothing under `~/.nook`. Run `nook adopt <host>`.
If the box has never run the boot script, `adopt` says so.

**`unknown nook '<name>'`** — `NOOK` names a box that is not adopted here, or
`~/.nook/default` points at one that was forgotten. `nook list` shows what
exists.

**The wrong box answered** — check `nook list` before anything else. `NOOK` in
the environment beats the default, and it is easy to leave exported in a shell.

**`every nbd device is in use`** — NBD devices come from one pool shared by the
whole machine. Eject another nook's drive, or raise the pool with
`sudo modprobe nbd nbds_max=32`.

**`cannot ssh to <host>`** — check `tailscale status` on both ends. If the peer
is listed and online but SSH still fails, the stale control socket is the usual
culprit: `rm ~/.ssh/nook-*` and retry. MagicDNS being off in the tailnet means
the hostname does not resolve at all; `20-tailscale` warns about this at boot.

**`ls ~/nook` hangs** — a stale sshfs mount after a suspend.

```bash
fusermount3 -uz ~/nook
systemctl --user restart nook-mount.service
```

The unit carries `reconnect` and `ServerAlive*` keepalives to make this rare,
not impossible.

**The drive is not in the file manager sidebar** — the udev rule is missing.
udisks files a network block device under system disks and hides it;
`/etc/udev/rules.d/99-nook.rules` sets `UDISKS_SYSTEM=0`. `install.sh` places
it, but skips silently when it cannot get sudo.

**`another machine has the disk attached`** — see [`drive.md`](drive.md). This
one is a real guard, not a glitch. Do not work around it.

**The bar widget shows "Not adopted" but the CLI works** — the widget runs
`nook status --json` with `timeout 8` and `BatchMode`. If SSH would prompt for
anything, the widget sees a failure where an interactive shell sees a prompt.
Fix the prompt, not the widget.

**The widget feels slow** — it polls `pollSeconds` (default 60) over the shared
control socket, plus one local-only `nook disk --local`. If the control socket
is not being reused, every poll pays a full handshake; confirm the
`# >>> nook` block is in `~/.ssh/config` and that `ControlPath` is writable.

## On the Pi

```bash
nook ssh systemctl status nbd-server            # NBD
nook ssh systemctl status rtslib-fb-targetctl   # iSCSI
nook ssh nook-target info
nook ssh journalctl -u docker --since -1h
nook ssh findmnt /mnt/nook
```

If `/mnt/nook` is not mounted, the external disk is gone or renamed. The fstab
entry is by UUID with `nofail`, so the Pi boots anyway and everything that
depends on the disk quietly has nowhere to live — which looks like several
unrelated failures at once. Check this before chasing them.

## Re-running the boot script

Safe, and usually the right repair for anything on the Pi side. It is
idempotent by design and re-installs `nook-target` and `nook-info` on the way
through.

```bash
nook ssh 'curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash'
```

Nothing gets formatted without `--format`.
