# shellcheck shell=bash
# Shared helpers: paths, which nook a command is talking to, and the SSH
# connection everything reuses.
#
# One directory per nook under ~/.nook, and a `default` file naming the one that
# commands use when nothing says otherwise. A Pi and a mini PC are two nooks,
# not two installations.

NOOK_HOME="${NOOK_HOME:-$HOME/.nook}"

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

nook_dir() { echo "$NOOK_HOME/$1"; }

nooks() {
  [[ -d $NOOK_HOME ]] || return 0
  # Dot-directories are skipped: a nook is named after a host, and anything
  # hidden in here belongs to something else.
  find "$NOOK_HOME" -mindepth 2 -maxdepth 2 -name config -not -path '*/.*' -print 2>/dev/null |
    sed 's|/config$||' | while read -r d; do basename "$d"; done | sort
}

default_nook() {
  [[ -f $NOOK_HOME/default ]] || return 1
  cat "$NOOK_HOME/default"
}

current_nook() {
  if [[ -n ${NOOK:-} ]]; then
    echo "$NOOK"
    return
  fi
  default_nook && return
  die "no nook adopted here — run: nook adopt <host>"
}

# One nook used to live in a single ~/.nook/config. Moving it under its own name
# costs nothing and means nobody has to re-adopt a box that already works.
migrate_single_nook() {
  local old="$NOOK_HOME/config" name
  [[ -f $old ]] || return 0
  name=$(sed -n 's/^NOOK_NAME=//p' "$old" | head -n1)
  name=${name:-$(sed -n 's/^NOOK_HOST=//p' "$old" | head -n1)}
  name=${name:-nook}
  mkdir -p "$NOOK_HOME/$name"
  mv "$old" "$NOOK_HOME/$name/config"
  printf '%s\n' "$name" >"$NOOK_HOME/default"
  log "moved the existing nook to $NOOK_HOME/$name"
}

# Sets NOOK, NOOK_DIR, NOOK_HOST, NOOK_DATA, NOOK_TRANSPORT and the values
# derived from them for the rest of a subcommand. Written by `nook adopt` from
# the box's own /etc/nook.conf, so the two never drift.
load_config() {
  migrate_single_nook
  # Cleared first, because this runs more than once per process — `nook status
  # --all` walks every box — and a `${VAR:-default}` below would otherwise keep
  # the previous nook's mount point, label and device.
  unset NOOK_HOST NOOK_DATA NOOK_TRANSPORT NOOK_MOUNT NOOK_LABEL NBD_DEV
  NOOK=$(current_nook)
  NOOK_DIR=$(nook_dir "$NOOK")
  [[ -f $NOOK_DIR/config ]] || die "unknown nook '$NOOK' — nook list"
  # shellcheck disable=SC1091
  source "$NOOK_DIR/config"
  : "${NOOK_HOST:?$NOOK_DIR/config has no NOOK_HOST — re-run: nook adopt}"

  NOOK_DATA=${NOOK_DATA:-/mnt/nook}
  NOOK_TRANSPORT=${NOOK_TRANSPORT:-none}
  NOOK_IQN_BASE=${NOOK_IQN_BASE:-iqn.2026-08.dev.nook}
  NOOK_INITIATOR_IQN="$NOOK_IQN_BASE:$(hostname)"

  # Everything below is per-nook by construction. Two boxes mounted at the same
  # path, or two drives carrying the same label, collide in ways that look like
  # the wrong machine answering.
  NOOK_MOUNT=${NOOK_MOUNT:-$HOME/nook/$NOOK}
  NOOK_CONTEXT="nook-$NOOK"
  # ext4 labels stop at 16 characters, and a truncated label still has to be
  # unique enough to tell two boxes apart at a glance.
  NOOK_LABEL=${NOOK_LABEL:-$(printf '%s' "$NOOK" | tr '[:lower:]-' '[:upper:]_' | cut -c1-16)}
  NBD_DEV=${NBD_DEV:-$(cat "$NOOK_DIR/nbd" 2>/dev/null || echo "")}
}

# BatchMode everywhere: a command that blocks on a password prompt is a command
# the bar widget and the menu rows hang on.
remote() { ssh -o BatchMode=yes "$NOOK_HOST" "$@"; }

# Where a device is mounted, or nothing. Asked rather than remembered — udisks
# picks the path and it changes with the label.
mounted_at() { findmnt -nro TARGET --source "$1" 2>/dev/null | head -n1; }

# One marked block in ~/.ssh/config covering every adopted nook, rewritten
# whenever the set changes. Per-nook blocks would leave a Host entry behind for
# a box that has been forgotten.
write_ssh_config() {
  local file="$HOME/.ssh/config" name host user
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [[ -f $file ]] || : >"$file"
  chmod 600 "$file"

  {
    while read -r name; do
      [[ -n $name ]] || continue
      host=$(sed -n 's/^NOOK_HOST=//p' "$(nook_dir "$name")/config" | head -n1)
      [[ -n $host ]] || continue
      user=$(sed -n 's/^NOOK_SSH_USER=//p' "$(nook_dir "$name")/config" | head -n1)
      cat <<BLOCK
Host $host
	HostName $host${user:+
	User $user}
	# One connection reused by every nook command. A fresh handshake per call is
	# what makes a status widget feel heavy.
	ControlMaster auto
	ControlPath ~/.ssh/nook-%r@%h:%p
	ControlPersist 5m
	ServerAliveInterval 15
	ServerAliveCountMax 3

BLOCK
    done < <(nooks)
  } | replace_block "$file" "# >>> nook" "# <<< nook" prepend
}

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
