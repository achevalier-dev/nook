# shellcheck shell=bash
# 40-docker — Docker, with its data on the external disk.
#
# The point is `nook up`: you keep compose files on your laptop and Docker runs
# them here over SSH, so there is no editing YAML in nano over a slow link.

if ! command -v docker >/dev/null; then
  note "installing docker"
  curl -fsSL https://get.docker.com | sh
fi

# Images and layers are the single biggest source of SD card wear on a Pi. If
# there is an external disk, that is where they belong.
if mountpoint -q "$NOOK_DATA" && [[ $(jq -r '."data-root" // ""' /etc/docker/daemon.json 2>/dev/null) != "$NOOK_DATA/docker" ]]; then
  install -d /etc/docker
  tmp=$(mktemp)
  jq --arg root "$NOOK_DATA/docker" '. + {"data-root": $root}' /etc/docker/daemon.json 2>/dev/null >"$tmp" ||
    printf '{"data-root":"%s"}\n' "$NOOK_DATA/docker" >"$tmp"
  mv "$tmp" /etc/docker/daemon.json
  systemctl restart docker
  note "docker data-root moved to $NOOK_DATA/docker"
fi

# Without this, every `nook up` from your laptop needs sudo on this end, and
# `host=ssh://` has nowhere to type a password.
id -nG "$NOOK_USER" | tr ' ' '\n' | grep -qx docker || {
  usermod -aG docker "$NOOK_USER"
  note "$NOOK_USER added to the docker group (takes effect on next login)"
}

systemctl enable --now docker >/dev/null
