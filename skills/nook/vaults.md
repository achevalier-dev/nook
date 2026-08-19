# Obsidian vaults

A bare git repo on the Pi. Not a sync daemon.

```bash
nook vault init main     # creates /mnt/nook/vaults/main.git
nook vault list
```

Then, in the vault directory:

```bash
git init
git remote add nook nook:/mnt/nook/vaults/main.git
```

In Obsidian, the **Git** plugin: commit-and-sync every 5 minutes, pull on
startup. Mobile Obsidian speaks the same remote.

## Why git and not a sync tool

The vault gets history, conflicts are git conflicts a person can actually
resolve, and it works offline by construction. Nothing extra runs on the Pi —
SSH is already there, so a bare repo costs no daemon, no port, and no memory.

## The alternative, and its cost

Opening a vault straight off `~/nook` also works: there is only one copy, so
there is nothing to sync. On a LAN it is fine. Over a slow link it is not —
Obsidian rewrites `.obsidian/workspace.json` constantly and the latency shows on
every pane change.

Never do both at once for the same vault. A git-synced local copy and a
mount-hosted copy of the same notes will fight.

## Not on the drive

Vaults belong in `/mnt/nook/vaults`, on the shared lane. Putting one inside the
network drive means only the machine currently holding the drive can reach it,
which defeats the point.
