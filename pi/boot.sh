#!/bin/bash
# boot.sh — turns a stock Raspberry Pi OS Lite install into a nook: reachable
# from anywhere over Tailscale, backed by an external disk, and offering that
# disk to your machines both as a folder and as a real block device.
#
# Safe to re-run. Every module checks its own work and skips what is done, so
# this doubles as the upgrade path.
#
#   curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash -s -- --format --shares

set -euo pipefail

NOOK_NAME=${NOOK_NAME:-nook}
NOOK_DATA=${NOOK_DATA:-/mnt/nook}
NOOK_STATE=/var/lib/nook
NOOK_CONF=/etc/nook.conf
NOOK_REPO_RAW=${NOOK_REPO_RAW:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi}

# IQN wants a date and a reversed domain you control; it is an identifier, not
# a URL, so it never has to resolve.
NOOK_IQN_BASE=${NOOK_IQN_BASE:-iqn.2026-08.dev.nook}
NOOK_DISK_SIZE=${NOOK_DISK_SIZE:-256G}

NOOK_FORMAT=${NOOK_FORMAT:-0}
NOOK_SHARES=${NOOK_SHARES:-0}
NOOK_USB_GADGET=${NOOK_USB_GADGET:-0}
SKIP=()

MODULES=(10-base 20-tailscale 30-storage 35-disk 40-docker 50-shares 60-usb-gadget)

usage() {
  cat <<'USAGE'
nook boot

  --name NAME       hostname and Tailscale name for this box (default: nook)
  --data PATH       where the external disk is mounted (default: /mnt/nook)
  --disk-size SIZE  size of the network flash drive image (default: 256G)
  --format          let nook create a filesystem on a blank external disk
  --shares          also run Samba, for phones and non-Linux machines
  --usb-gadget      also offer the disk over a USB-C cable (read the warning)
  --skip MODULE     skip a module by name, repeatable
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
  --name) NOOK_NAME=$2; shift 2 ;;
  --data) NOOK_DATA=$2; shift 2 ;;
  --disk-size) NOOK_DISK_SIZE=$2; shift 2 ;;
  --format) NOOK_FORMAT=1; shift ;;
  --shares) NOOK_SHARES=1; shift ;;
  --usb-gadget) NOOK_USB_GADGET=1; shift ;;
  --skip) SKIP+=("$2"); shift 2 ;;
  --help | -h) usage; exit 0 ;;
  *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Re-exec under sudo rather than refusing, so the one-liner stays one line.
# -E keeps the NOOK_* environment the user may have set in front of it.
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "run this as root, or install sudo" >&2; exit 1; }
  exec sudo -E bash "$0" "$@"
fi

. /etc/os-release
if [[ ${ID:-} != debian && ${ID_LIKE:-} != *debian* ]]; then
  echo "boot.sh targets Raspberry Pi OS / Debian; found ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

# The user who invoked sudo owns the data directory and the docker group —
# root owning everything is how a home server ends up needing sudo to read a PDF.
NOOK_USER=${SUDO_USER:-$(id -un 1000 2>/dev/null || echo pi)}
NOOK_HOME=$(getent passwd "$NOOK_USER" | cut -d: -f6)

mkdir -p "$NOOK_STATE"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mwarning:\033[0m %s\n' "$*" >&2; }

skipped() {
  local m
  for m in ${SKIP+"${SKIP[@]}"}; do [[ $m == "$1" ]] && return 0; done
  return 1
}

# Modules are fetched rather than embedded so a re-run of the same one-liner
# picks up fixes without anyone having to find a new URL. A checkout on disk
# wins, which is what makes `git clone && sudo pi/boot.sh` a working dev loop.
source_module() {
  local name=$1 local_path="$(dirname -- "${BASH_SOURCE[0]}")/modules/$1.sh" cached="$NOOK_STATE/$1.sh"
  if [[ -r $local_path ]]; then
    # shellcheck disable=SC1090
    . "$local_path"
    return
  fi
  curl -fsSL "$NOOK_REPO_RAW/modules/$name.sh" -o "$cached.tmp"
  mv "$cached.tmp" "$cached"
  # shellcheck disable=SC1090
  . "$cached"
}

# Same story for the helper scripts the modules install: prefer the checkout,
# fall back to the raw URL.
install_bin() {
  local name=$1 src="$(dirname -- "${BASH_SOURCE[0]}")/bin/$1" dest=/usr/local/bin/$1
  if [[ -r $src ]]; then
    install -m 755 "$src" "$dest"
  else
    curl -fsSL "$NOOK_REPO_RAW/bin/$name" -o "$dest.tmp"
    install -m 755 "$dest.tmp" "$dest"
    rm -f "$dest.tmp"
  fi
}

for module in "${MODULES[@]}"; do
  if skipped "$module"; then
    log "$module (skipped)"
    continue
  fi
  log "$module"
  source_module "$module"
done

# Written last so the file only describes a box that actually got built, and so
# the CLI on your laptop can read the choices back instead of guessing them.
cat >"$NOOK_CONF" <<CONF
NOOK_NAME=$NOOK_NAME
NOOK_DATA=$NOOK_DATA
NOOK_USER=$NOOK_USER
NOOK_IQN_BASE=$NOOK_IQN_BASE
NOOK_TARGET_IQN=$NOOK_IQN_BASE:$NOOK_NAME
NOOK_DISK_IMG=$NOOK_DATA/disk.img
NOOK_TRANSPORT=${NOOK_TRANSPORT:-none}
CONF

cat <<NOTE

  nook is up as "$NOOK_NAME".

  From your laptop:

      nook adopt $NOOK_NAME

NOTE
