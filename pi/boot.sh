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
# The whole repository, for the one thing a raw file URL cannot give a box: the
# catalogue of services, which is a directory rather than a file.
NOOK_REPO_TARBALL=${NOOK_REPO_TARBALL:-https://codeload.github.com/achevalier-dev/nook/tar.gz/main}
NOOK_BOOT_URL=${NOOK_BOOT_URL:-$NOOK_REPO_RAW/boot.sh}
# The repository root, for pointing at the client installer at the end.
NOOK_BOOT_URL_BASE=${NOOK_BOOT_URL_BASE:-${NOOK_REPO_RAW%/pi}}

# IQN wants a date and a reversed domain you control; it is an identifier, not
# a URL, so it never has to resolve.
NOOK_IQN_BASE=${NOOK_IQN_BASE:-iqn.2026-08.dev.nook}
NOOK_DISK_SIZE=${NOOK_DISK_SIZE:-256G}

NOOK_FORMAT=${NOOK_FORMAT:-0}
NOOK_SHARES=${NOOK_SHARES:-0}
NOOK_USB_GADGET=${NOOK_USB_GADGET:-0}
NOOK_DETACH=${NOOK_DETACH:-0}
NOOK_AUTO_UPGRADE=${NOOK_AUTO_UPGRADE:-1}
NOOK_MANAGE=${NOOK_MANAGE:-1}
NOOK_API_PORT=${NOOK_API_PORT:-8881}
SKIP=()

MODULES=(10-base 20-tailscale 30-storage 35-disk 40-docker 45-status 50-shares 55-api 60-usb-gadget 70-upgrade)

# Kept whole, because the loop below consumes $@ and the sudo re-exec further
# down still has to pass the flags on. Without this, `--format` is parsed here
# and then quietly lost on the way to root.
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'USAGE'
nook boot

  --name NAME       hostname and Tailscale name for this box (default: nook)
  --data PATH       where the external disk is mounted (default: /mnt/nook)
  --disk-size SIZE  size of the network flash drive image (default: 256G)
  --format          let nook create a filesystem on a blank external disk
  --shares          also run Samba, for phones and non-Linux machines
  --usb-gadget      also offer the disk over a USB-C cable (read the warning)
  --no-auto-upgrade do not upgrade services weekly on their own
  --no-manage       index page lists services but cannot add or remove them
  --detach          run in the background, surviving a dropped connection
  --no-detach       stay in the foreground even on a fragile session
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
  --no-auto-upgrade) NOOK_AUTO_UPGRADE=0; shift ;;
  --no-manage) NOOK_MANAGE=0; shift ;;
  --detach) NOOK_DETACH=1; shift ;;
  --no-detach) NOOK_DETACH=0; NOOK_DETACHED=1; shift ;;
  --skip) SKIP+=("$2"); shift 2 ;;
  --help | -h) usage; exit 0 ;;
  *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Re-exec under sudo rather than refusing, so the one-liner stays one line.
# -E keeps the NOOK_* environment the user may have set in front of it.
#
# Piped from curl there is no script on disk to hand to sudo: bash read this
# from stdin, so $0 and BASH_SOURCE both name the bash binary, and passing that
# to `sudo bash` runs the interpreter as its own input — "cannot execute binary
# file". So check that what we are pointed at is really this script, and fetch a
# fresh copy on the other side of the privilege line when it is not.
self_path() {
  local src=${BASH_SOURCE[0]:-}
  [[ -n $src && -f $src && -r $src ]] || return 1
  grep -q "^NOOK_REPO_RAW=" "$src" 2>/dev/null || return 1
  printf '%s\n' "$src"
}

# How to run this script again, as one shell command. Both the privilege
# re-exec and the detach below need it.
rerun_command() {
  local self forwarded=""
  # printf %q with no arguments still emits one empty word, which would reach
  # the flag parser as an unknown option.
  ((${#ORIGINAL_ARGS[@]})) && forwarded=" $(printf '%q ' "${ORIGINAL_ARGS[@]}")"
  if self=$(self_path); then
    printf 'bash %q%s' "$self" "$forwarded"
  else
    printf 'curl -fsSL %q | bash -s --%s' "$NOOK_BOOT_URL" "$forwarded"
  fi
}

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "run this as root, or install sudo" >&2; exit 1; }
  self_path >/dev/null || command -v curl >/dev/null ||
    { echo "curl is needed to re-run this under sudo" >&2; exit 1; }
  exec sudo -E bash -c "$(rerun_command)"
fi

# Installing packages and bringing Tailscale up restarts services. On a box you
# are driving through Raspberry Pi Connect, one of those services is the session
# you are typing in: the run dies halfway and leaves apt half-finished, which is
# worse than never starting. So on such a session the work moves into a
# transient systemd unit that outlives the connection.
session_is_fragile() {
  local pid=$PPID comm
  while [[ ${pid:-0} -gt 1 ]]; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
    case $comm in
      rpi-connect* | *connect-agent* | *connect-shell*) return 0 ;;
    esac
    # Field 4 of /proc/PID/stat is the parent pid.
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || return 1
  done
  return 1
}

# Printing "now go and run journalctl" is asking someone to do what this can do
# itself. Follow the unit until it stops, then hand back its result.
follow_boot() {
  local pid status
  journalctl -fu nook-boot --no-pager &
  pid=$!
  # The unit's own state is the only thing that knows when it is done; the log
  # has no reliable last line. A moment first, because a just-started unit is
  # not active yet.
  sleep 2
  while systemctl is-active --quiet nook-boot; do sleep 2; done
  # Let the last lines land before the pager is killed.
  sleep 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  status=$(systemctl show -p Result --value nook-boot 2>/dev/null || echo unknown)
  if [[ $(systemctl show -p LoadState --value nook-boot 2>/dev/null) != not-found ]]; then
    systemctl reset-failed nook-boot 2>/dev/null || true
  fi
  if [[ $status == success ]]; then
    exit 0
  fi
  echo
  echo "  The run did not finish ($status). The log above says where it stopped;" >&2
  echo "  fixing that and running this again picks up where it left off." >&2
  exit 1
}

if [[ -z ${NOOK_DETACHED:-} ]] && { [[ $NOOK_DETACH == 1 ]] || session_is_fragile; }; then
  if command -v systemd-run >/dev/null; then
    cat <<'DETACH'

  This session can be cut off by the services this script restarts, so the work
  runs in the background instead. Nothing is lost if you get disconnected.

  Tailscale's login link appears below when it is ready. Ctrl-C stops watching;
  the run itself keeps going, and re-running this command picks the log back up.

DETACH
    # A run already going is the common case for anyone who lost their session
    # and came back — joining it beats colliding with it.
    if systemctl is-active --quiet nook-boot 2>/dev/null; then
      echo "  A run is already going. Following it instead of starting another."
      echo
      follow_boot
    fi
    # A finished or failed unit stays loaded until something clears it, and
    # systemd-run refuses to reuse the name while it is there. Only touch it if
    # it is actually loaded — systemd logs a complaint for each call otherwise,
    # into the very journal we are about to show.
    if [[ $(systemctl show -p LoadState --value nook-boot 2>/dev/null) != not-found ]]; then
      systemctl stop nook-boot 2>/dev/null || true
      systemctl reset-failed nook-boot 2>/dev/null || true
    fi
    systemd-run --unit=nook-boot --description="nook boot script" \
      --setenv=NOOK_DETACHED=1 --quiet -- bash -c "$(rerun_command)"
    follow_boot
  fi
  echo "    warning: no systemd-run here — staying in the foreground" >&2
fi

. /etc/os-release
if [[ ${ID:-} != debian && ${ID_LIKE:-} != *debian* ]]; then
  echo "boot.sh targets Raspberry Pi OS / Debian; found ${PRETTY_NAME:-unknown}" >&2
  exit 1
fi

# The user who invoked sudo owns the data directory and the docker group —
# root owning everything is how a home server ends up needing sudo to read a PDF.
NOOK_USER=${SUDO_USER:-$(id -un 1000 2>/dev/null || echo pi)}

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
  local name=$1 local_path cached
  local_path="$(dirname -- "${BASH_SOURCE[0]}")/modules/$1.sh"
  cached="$NOOK_STATE/$1.sh"
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
  local name=$1 src dest=/usr/local/bin/$1
  src="$(dirname -- "${BASH_SOURCE[0]}")/bin/$1"
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
NOOK_API_PORT=$NOOK_API_PORT
NOOK_MANAGE=$NOOK_MANAGE
CONF

# What you actually got, stated once. A run that ends in a list of what is on
# and what is off reads as deliberate; one that ends in scattered warnings reads
# as broken, even when it is the same box.
row() { printf '    %-12s %s\n' "$1" "$2"; }

printf '\n\033[1m  nook is up as "%s"\033[0m\n\n' "$NOOK_NAME"
row reachable "${NOOK_TS_IP:-not on a tailnet} — ssh $NOOK_USER@$NOOK_NAME"
row folder "$NOOK_DATA/files$([[ ${NOOK_HAS_EXTERNAL:-0} == 1 ]] || echo "  (on the system disk)")"

case ${NOOK_TRANSPORT:-none} in
  none) row drive "off — not enough room for one on $NOOK_DATA" ;;
  *) row drive "$NOOK_TRANSPORT, $(numfmt --to=iec --format='%.0f' "$(stat -c %s "$NOOK_DATA/disk.img" 2>/dev/null || echo 0)")" ;;
esac

row containers "$(command -v docker >/dev/null && echo "docker ready" || echo "not installed")"
row upgrades "$(systemctl is-enabled nook-upgrade.timer >/dev/null 2>&1 && echo "weekly, automatic" || echo "manual")"
row page "$(systemctl is-enabled nook-api.socket >/dev/null 2>&1 && echo "add, update and remove from the browser" || echo "read-only")"
[[ $NOOK_SHARES == 1 ]] && row samba "smb://$NOOK_NAME/files"

cat <<NOTE

  On the machine you use, if you have not already:

      curl -fsSL $NOOK_BOOT_URL_BASE/bootstrap.sh | bash

  That installs the nook command and adopts this box on its own.

NOTE
