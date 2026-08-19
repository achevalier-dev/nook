# Containers

Compose files live on the machine you use. The containers run on the Pi. There
is no editing YAML in nano over SSH.

```bash
nook up ~/stacks/media     # compose up -d --remove-orphans, over there
nook down ~/stacks/media
nook ps
nook logs [SERVICE]
```

All of it is `DOCKER_CONTEXT=nook docker …` with `host=ssh://<host>`, over the
same reused SSH connection as everything else. `nook adopt` creates or updates
that context.

## Bind mounts point at the Pi

Paths in a compose file are resolved on the Pi, not locally. `/mnt/nook/files`
is the shared lane and the right place for container data. Do not bind-mount
anything into `/mnt/nook/disk.img`'s territory — that image belongs to whichever
machine has the drive attached.

## Publishing ports

Nothing should bind `0.0.0.0`. Bind loopback and let Tailscale publish it with a
real certificate:

```yaml
ports:
  - "127.0.0.1:5001:5001"
```

```bash
nook ssh sudo tailscale serve --bg 5001
```

## Building for the Pi

Build on your laptop's much faster CPU and push to a registry rather than
compiling on the Pi:

```bash
docker buildx build --platform linux/arm64 --push -t ghcr.io/you/thing .
```

## Docker's data lives on the external disk

`40-docker` sets `data-root` to `/mnt/nook/docker` when the external disk is
mounted. Images and layers are the single biggest source of SD card wear on a
Pi. If someone reports the disk filling, check there first:

```bash
nook ssh docker system df
```
