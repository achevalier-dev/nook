# Contributing

## Before a pull request

```bash
./script/check
```

Everything CI runs, and it needs no Raspberry Pi: the behaviour tests stub the
SSH connection, `sudo` and the block device. If `shellcheck` is not installed
locally the lint pass skips itself and CI runs it instead.

## What a change looks like

A new subcommand is a `cmd_<name>` function in the `lib/` file that owns its
area plus a case arm in `bin/nook`. `test/dispatch_test.sh` fails if you add one
without the other, in either direction.

A new step on the Pi is a file in `pi/modules/` plus its name in the `MODULES`
array in `pi/boot.sh`. Modules are sourced: use `return`, never `exit`, and
remember that `set -e` is already on.

Read [AGENTS.md](AGENTS.md) first — it is short, and the shell rules in it come
from bugs that have already happened here.

## The line that matters

The drive is a block device and exactly one machine may hold it read-write.
Changes that weaken `cmd_attach`'s holder check, or that add a way to reach the
export without going through it, will not be merged. If you need simultaneous
access, that is what the shared folder is for.

The same goes for the transports' bindings: iSCSI ships without CHAP and NBD has
no authentication at all, so both are bound to the Tailscale address. That
binding is the entire security boundary.

## Style

Comments explain *why*, not what. If a line needs a comment to say what it does,
the line is the problem. Prefer early returns, keep functions small, and match
what is already in the file you are editing.
