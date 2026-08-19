# shellcheck shell=bash
# Shared helpers: paths, config access, and the SSH connection everything reuses.

NOOK_HOME="${NOOK_HOME:-$HOME/.nook}"
NOOK_CONFIG="$NOOK_HOME/config"

die() {
  echo "nook: $*" >&2
  exit 1
}

log() { echo "  $*" >&2; }

need() {
  command -v "$1" >/dev/null || die "$1 is not on PATH${2:+ ($2)}"
}

# Said twice on purpose: the menu rows in omarchy-nook run the same commands as
# a terminal does, and a notification is the only output a menu row has.
notify() {
  echo "$1"
  command -v omarchy-notification-send >/dev/null &&
    omarchy-notification-send -g "󰋊" "nook" "$1" >/dev/null 2>&1 || true
}

# Sets NOOK_HOST, NOOK_DATA, NOOK_TRANSPORT, NOOK_TARGET_IQN and friends for the
# rest of a subcommand. Written by `nook adopt` from the Pi's own /etc/nook.conf,
# so the two never drift.
load_config() {
  [[ -f $NOOK_CONFIG ]] || die "no nook adopted here — run: nook adopt"
  # shellcheck disable=SC1090
  source "$NOOK_CONFIG"
  : "${NOOK_HOST:?$NOOK_CONFIG has no NOOK_HOST — re-run: nook adopt}"
  NOOK_DATA=${NOOK_DATA:-/mnt/nook}
  NOOK_MOUNT=${NOOK_MOUNT:-$HOME/nook}
  NOOK_TRANSPORT=${NOOK_TRANSPORT:-none}
  NOOK_IQN_BASE=${NOOK_IQN_BASE:-iqn.2026-08.dev.nook}
  NOOK_LABEL=${NOOK_LABEL:-NOOK}
  NOOK_INITIATOR_IQN="$NOOK_IQN_BASE:$(hostname)"
  NBD_DEV=${NBD_DEV:-/dev/nbd0}
}

# BatchMode everywhere: a command that blocks on a password prompt is a command
# the bar widget and the menu rows hang on.
remote() { ssh -o BatchMode=yes "$NOOK_HOST" "$@"; }

# Where a device is mounted, or nothing. Asked rather than remembered — udisks
# picks the path and it changes with the label.
mounted_at() { findmnt -nro TARGET --source "$1" 2>/dev/null | head -n1; }

# Replace a marked block in a config file we do not own, leaving everything
# else exactly as it was. Reads the block on stdin.
#   replace_block <file> <begin marker> <end marker> [prepend]
replace_block() {
  need python3
  local file=$1 begin=$2 end=$3 where=${4:-append} block
  block=$(cat)
  mkdir -p "$(dirname "$file")"
  [[ -f $file ]] || : >"$file"
  python3 - "$file" "$begin" "$end" "$where" "$block" <<'PY'
import pathlib, re, sys

path, begin, end, where, body = sys.argv[1:6]
block = f"{begin}\n{body}\n{end}\n"
text = path_text = pathlib.Path(path).read_text()

if begin in text and end in text:
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", lambda m: block, text, flags=re.S)
elif where == "prepend":
    # Host blocks in ssh_config are first-match-wins, so a block that has to win
    # goes on top or a wildcard further up swallows it.
    text = block + "\n" + text
else:
    text = (text.rstrip() + "\n\n" if text.strip() else "") + block

if text != path_text:
    pathlib.Path(path).write_text(text)
PY
}
