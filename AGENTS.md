# nook development context

## Stack

Bash, `ssh`, `rsync`, `jq`, and the kernel's own iSCSI or NBD client. No daemon,
no database, no build step. The Pi side is plain Debian and shell. If a change
needs a new runtime, it probably needs a different design.

## Structure

```
bin/nook           dispatcher — flag parsing lives in the subcommands, not here
lib/common.sh      paths, config, die/log/need/notify, the reused SSH connection
lib/<topic>.sh     one file per area, exporting cmd_<name> functions
pi/boot.sh         the one-liner that turns a Pi into a nook
pi/modules/*.sh    one file per concern, sourced by boot.sh in order
pi/bin/*           helpers installed onto the Pi
skills/nook/       the Claude Code skill and its topic guides
systemd/           the sshfs mount unit
udev/              the rule that makes the drive show as removable
```

A new subcommand is a `cmd_<name>` function in the `lib/` file that owns its
area, plus a case arm in `bin/nook`. Nothing else — `test/dispatch_test.sh`
fails if the two disagree in either direction.

## The two lanes

Everything in this repo divides along one line, and changes that blur it are
wrong:

- **The shared folder** (`/mnt/nook/files`, SFTP, `~/nook`) — many machines at
  once. Containers on the Pi read the same directory.
- **The drive** (`/mnt/nook/disk.img`, iSCSI or NBD) — exactly one machine at a
  time. A filesystem on a block device assumes it owns the device.

`cmd_attach` asks the Pi who holds the drive before doing anything.
`test/drive_guard_test.sh` exists to keep that guard in place.

## Shell rules

`set -euo pipefail` is on everywhere, including inside the sourced modules on
the Pi. Two consequences that have already caused bugs here:

- A bare `[[ cond ]] && action` guard ends the script when the condition is
  false. Write `if`. `test/boot_modules_test.sh` checks for this.
- `pi/modules/*.sh` are **sourced**, not executed. A module that gives up early
  uses `return`; an `exit` takes the whole boot run down halfway.

Files nook does not own — `~/.ssh/config`, `smb.conf`, `omarchy-menu.jsonc` —
are edited through `replace_block`, between markers, never appended to blindly.

## Run & test

```bash
./script/check                        # syntax, shellcheck, json, four behaviour tests
NOOK_HOME=/tmp/nook-test ./bin/nook status
```

`script/check` is everything CI runs and needs no Pi, no network and no
credentials: the behaviour tests stub `remote`, `sudo` and the block device.
Run it after every edit.

Beyond that, test against a real nook with `NOOK_HOME` pointed somewhere
disposable. Anything destructive — `format`, `resize` — gets stubbed rather than
run.

## The Omarchy side

The bar widget and the menu rows live in
[omarchy-nook](https://github.com/achevalier-dev/omarchy-nook), and call this
CLI. Keep `nook status --json` and `nook disk --local` stable: they are that
repo's API, and the widget polls them.
