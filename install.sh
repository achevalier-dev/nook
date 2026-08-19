#!/bin/bash
# Installs the nook CLI, the mount unit, and the Omarchy menu rows on this
# machine. Nothing here touches the Pi — that is `nook adopt`.
#
# Safe to re-run: the menu block is replaced in place, never duplicated.

set -euo pipefail

NAME="nook"
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"

for tool in ssh rsync jq; do
  command -v "$tool" >/dev/null || echo "warning: $tool is not on PATH" >&2
done
command -v sshfs >/dev/null || echo "note: sshfs is missing — 'nook mount' needs it (pacman -S sshfs)" >&2
command -v udisksctl >/dev/null || echo "note: udisks2 is missing — 'nook attach' will fall back to sudo mount" >&2

mkdir -p "$BIN_DIR"
ln -sf "$REPO/bin/$NAME" "$BIN_DIR/$NAME"
echo "linked $BIN_DIR/$NAME -> $REPO/bin/$NAME"

SKILL_DIR="$HOME/.claude/skills"

mkdir -p "$UNIT_DIR"
ln -sf "$REPO/pc/nook-mount.service" "$UNIT_DIR/nook-mount.service"
systemctl --user daemon-reload
echo "installed nook-mount.service (enabled by 'nook adopt')"

# Symlinked rather than copied, the way omarchy links its own skills, so a
# git pull updates the guides without a reinstall.
mkdir -p "$SKILL_DIR"
ln -sfn "$REPO/agents/skills/nook" "$SKILL_DIR/nook"
echo "linked $SKILL_DIR/nook -> $REPO/agents/skills/nook"

# Optional and asked for explicitly: the rule only changes how the file manager
# categorises the drive, so a machine where sudo is inconvenient still works.
if [[ ${NOOK_SKIP_UDEV:-0} != 1 ]]; then
  if sudo -n true 2>/dev/null || [[ -t 0 ]]; then
    sudo install -m 644 "$REPO/pc/99-nook.rules" /etc/udev/rules.d/99-nook.rules
    sudo udevadm control --reload
    echo "installed /etc/udev/rules.d/99-nook.rules"
  else
    echo "note: skipped the udev rule (no sudo) — the drive still works, it just lands under system disks" >&2
  fi
fi

mkdir -p "$(dirname "$MENU")"
[[ -s $MENU ]] || printf '{\n}\n' >"$MENU"
cp "$MENU" "$MENU.bak.$(date +%s)"

python3 - "$REPO/extensions/nook.jsonc" "$MENU" "$NAME" <<'PY'
import pathlib, re, sys

snippet = pathlib.Path(sys.argv[1]).read_text().rstrip()
target = pathlib.Path(sys.argv[2])
name = sys.argv[3]

begin, end = f"  // >>> {name}", f"  // <<< {name}"
block = f"{begin}\n{snippet}\n{end}\n"
text = target.read_text()

if begin in text and end in text:
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", lambda m: block, text, flags=re.S)
else:
    cut = text.rstrip().rfind("}")
    if cut < 0:
        raise SystemExit(f"{target} is not a JSON object; refusing to edit it")
    # Keep whatever follows the closing brace — a trailing comment there is the
    # user's, and dropping it would be editing config we were not asked to.
    tail = text[cut:]
    head = text.rstrip()[:cut].rstrip()
    # JSONC tolerates a trailing comma but not a missing one. The comma belongs
    # on the last entry, which is not the last line when a block ends in a
    # comment — putting it there would comment the comma out.
    lines = head.splitlines()
    for i in range(len(lines) - 1, -1, -1):
        stripped = lines[i].strip()
        if not stripped or stripped.startswith("//"):
            continue
        if not stripped.endswith(",") and not stripped.endswith("{"):
            lines[i] = lines[i].rstrip() + ","
        break
    head = "\n".join(lines)
    text = head + "\n" + block + tail
    if not text.endswith("\n"):
        text += "\n"

target.write_text(text)
PY

echo "menu rows installed in $MENU (previous version backed up alongside it)"
omarchy menu refresh >/dev/null 2>&1 || true

cat <<'NOTE'

Next, on the Pi:

    curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash

then back here:

    nook adopt

NOTE
