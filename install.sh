#!/usr/bin/env bash
# Links nook onto PATH, installs the Claude skill, the mount unit and the udev
# rule. Safe to re-run: everything is a symlink or an overwrite.
#
# This installs the client. The Pi side is pi/boot.sh, run over there.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
SKILL_DIR="$HOME/.claude/skills"
UNIT_DIR="$HOME/.config/systemd/user"

# Say exactly what to run on this machine, rather than naming a missing tool
# and leaving the reader to work it out.
pkg_hint() {
  case "$1" in
    pacman) echo "sudo pacman -S $2" ;;
    apt) echo "sudo apt install $3" ;;
    dnf) echo "sudo dnf install $3" ;;
    *) echo "install $2" ;;
  esac
}

MGR=none
command -v pacman >/dev/null && MGR=pacman
[[ $MGR == none ]] && command -v apt >/dev/null && MGR=apt
[[ $MGR == none ]] && command -v dnf >/dev/null && MGR=dnf

# Bootstrap has already checked and installed all of this. Repeating it here
# makes one install look like two, with the same notes printed twice.
if [[ ${NOOK_FROM_BOOTSTRAP:-0} != 1 ]]; then

missing=()
#          command    arch name  debian/fedora name
check() {
  command -v "$1" >/dev/null && return 0
  missing+=("$1")
  echo "missing: $1 — $(pkg_hint "$MGR" "$2" "$3")" >&2
}

check ssh openssh openssh-client
check jq jq jq
check rsync rsync rsync
check sshfs sshfs sshfs
check udisksctl udisks2 udisks2

if [[ ${#missing[@]} -gt 0 ]]; then
  echo >&2
  echo "nook is installed, but install the above before using it." >&2
  echo >&2
fi

# The transport is decided by the Pi's kernel, not by preference, so which of
# these you need is not knowable until `nook adopt` has read its config.
command -v iscsiadm >/dev/null || command -v nbd-client >/dev/null ||
  echo "note: 'nook attach' needs open-iscsi or nbd — 'nook doctor' names the one your nook uses" >&2
fi

mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/nook" "$BIN_DIR/nook"
echo "linked $BIN_DIR/nook -> $REPO/bin/nook"

# Symlinked as a directory, not file by file: the skill is SKILL.md plus five
# topic guides, and a git pull should update all of them at once.
if [[ $REPO == *"/.claude/plugins/"* ]]; then
  echo "running inside a Claude Code plugin — the skill comes from the plugin"
else
  mkdir -p "$SKILL_DIR"
  ln -sfn "$REPO/skills/nook" "$SKILL_DIR/nook"
  echo "linked $SKILL_DIR/nook -> $REPO/skills/nook"
fi

if command -v systemctl >/dev/null; then
  mkdir -p "$UNIT_DIR"
  # Templated on the nook's name: one instance per box, enabled by `nook adopt`.
  cp -f "$REPO/systemd/nook-mount@.service" "$UNIT_DIR/"
  rm -f "$UNIT_DIR/nook-mount.service"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "installed $UNIT_DIR/nook-mount@.service"

  # A machine nobody thinks about is the one that ends up months behind, and a
  # stale nook here reads as features that stopped working rather than as an old
  # version. So the daily update goes on by itself — but never over somebody's
  # working copy: a checkout with local changes would refuse the fast-forward
  # every night, and one being edited is not an installer's business.
  if [[ ${NOOK_NO_AUTO_UPDATE:-0} != 1 ]] &&
    git -C "$REPO" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 &&
    [[ -z $(git -C "$REPO" status --porcelain 2>/dev/null) ]]; then
    cp -f "$REPO/systemd/nook-update.service" "$REPO/systemd/nook-update.timer" "$UNIT_DIR/"
    systemctl --user daemon-reload 2>/dev/null || true
    if systemctl --user enable --now nook-update.timer >/dev/null 2>&1; then
      echo "nook updates itself daily — nook update --no-auto turns that off"
    fi
  fi
else
  echo "no systemd here — 'nook mount' will call sshfs directly" >&2
fi

# Optional, and asked for explicitly: the rule only changes how the file manager
# categorises the drive, so a machine where sudo is inconvenient still works.
if [[ ${NOOK_SKIP_UDEV:-0} != 1 ]]; then
  if sudo -n true 2>/dev/null || [[ -t 0 ]]; then
    sudo install -m 644 "$REPO/udev/99-nook.rules" /etc/udev/rules.d/99-nook.rules
    sudo udevadm control --reload
    echo "installed /etc/udev/rules.d/99-nook.rules"
  else
    echo "note: skipped the udev rule (no sudo) — the drive still works, it just lands under system disks" >&2
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" >&2 ;;
esac

cat <<'EOF'

next:
  on the box:  curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash
  here:        nook adopt <hostname>

  or do both from here:  nook boot <hostname>
  more than one box? adopt each, then: nook list / nook use <name>
EOF
