---
description: What the nook is doing right now, and what to do about it
---

Run `nook status` and `nook doctor`, then answer `$ARGUMENTS` from what they say.

`status` is the nook's own view — uptime, temperature, load, disk, containers,
and how many machines hold the drive. `doctor` is this machine's view: the
tailnet peer, SSH, which transport the nook uses, whether the client package for
it is installed, and whether the drive is attached here.

Read the `nook` skill before acting on any of it. In particular: the drive is a
block device and exactly one machine may hold it read-write, so never work
around a refusal from `nook attach` by calling `iscsiadm` or `nbd-client`
directly.

If both commands are clean, say so in one line rather than restating every
field.
