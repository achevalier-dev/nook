#!/usr/bin/env bash
# One command: dependencies, nook itself, and the Claude Code skill.
#
#   curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/bootstrap.sh | bash
#
# Flags (pass with `| bash -s -- --flag`):
#   --dry-run   print what would happen, change nothing
#   --no-deps   skip package installation

set -euo pipefail

REPO_URL=${NOOK_REPO:-https://github.com/achevalier-dev/nook}
SRC=${NOOK_SRC:-$HOME/.local/share/nook}
DRY=0
DEPS=1

for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    --no-deps) DEPS=0 ;;
    -h | --help)
      sed -n '2,11p' "$0" 2>/dev/null || true
      exit 0
      ;;
  esac
done

# Piped from curl, stdin is the script itself, so a prompt has to read the
# terminal directly or it silently eats the next line of the installer.
ask() {
  local answer
  [[ $DRY == 0 && -r /dev/tty ]] || return 1
  printf '\033[1m%s\033[0m [Y/n] ' "$*" >/dev/tty
  read -r answer </dev/tty || return 1
  [[ -z $answer || $answer == [Yy]* ]]
}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

run() {
  if [[ $DRY == 1 ]]; then
    dim "would run: $*"
  else
    dim "$*"
    "$@"
  fi
}

# ---------------------------------------------------------------- environment

[[ $(uname -s) == Linux ]] ||
  warn "the nook client is Linux-only — sshfs and the block-device clients are not portable"

MGR=none
if command -v pacman >/dev/null; then MGR=pacman
elif command -v apt >/dev/null; then MGR=apt
elif command -v dnf >/dev/null; then MGR=dnf
fi

SUDO=""
[[ $EUID -ne 0 ]] && command -v sudo >/dev/null && SUDO=sudo

signed_in() {
  tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'
}

tailnet_name() {
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//'
}

bold "nook installer"
dim "package manager: $MGR"

# ---------------------------------------------------------------- dependencies

missing=()
for tool in git ssh jq rsync sshfs udisksctl tailscale; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done

pkg_name() {
  case "$MGR:$1" in
    pacman:ssh) echo openssh ;;
    apt:tailscale | dnf:tailscale) echo "" ;;
    apt:ssh | dnf:ssh) echo openssh-client ;;
    *:udisksctl) echo udisks2 ;;
    *) echo "$1" ;;
  esac
}

install_missing() {
  local pkgs=() t name
  for t in "${missing[@]}"; do
    name=$(pkg_name "$t")
    # Debian and Fedora do not carry tailscale; its own installer adds the
    # repository and is the documented way in.
    if [[ -z $name ]]; then
      run bash -c "curl -fsSL https://tailscale.com/install.sh | sh"
      continue
    fi
    pkgs+=("$name")
  done
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  case $MGR in
    pacman) run $SUDO pacman -S --needed --noconfirm "${pkgs[@]}" ;;
    apt) run $SUDO apt-get update -qq && run $SUDO apt-get install -y "${pkgs[@]}" ;;
    dnf) run $SUDO dnf install -y "${pkgs[@]}" ;;
    *) warn "no package manager found — install by hand: ${pkgs[*]}" ;;
  esac
}

if [[ ${#missing[@]} -gt 0 ]]; then
  step "Installing ${missing[*]}"
  if [[ $DEPS == 1 ]]; then install_missing; else dim "skipped (--no-deps)"; fi
else
  step "Dependencies already present"
fi

# Reaching a nook at all means being on the same tailnet as it. Installing the
# package is only half of that — the machine still has to be signed in, and
# nothing else here can do it for you.
step "Tailscale"
if command -v tailscale >/dev/null; then
  if ! command -v systemctl >/dev/null; then
    warn "no systemd here — start tailscaled however this machine does it"
  elif [[ $DRY == 0 ]]; then
    systemctl is-active --quiet tailscaled 2>/dev/null || run $SUDO systemctl enable --now tailscaled
  fi
  if signed_in; then
    dim "signed in as $(tailnet_name)"
  else
    echo
    echo "  This machine is not on a tailnet yet, and that is how nook reaches a box."
    echo "  Signing in opens a browser — use the same account as the box."
    echo
    if ask "  Sign in now?"; then
      $SUDO tailscale up || warn "tailscale up did not finish — run it again when ready"
      signed_in && dim "signed in as $(tailnet_name)"
    else
      warn "skipped — run this before 'nook adopt':  sudo tailscale up"
    fi
  fi
else
  warn "tailscale could not be installed — nook reaches boxes over it:"
  warn "  https://tailscale.com/download"
fi

# The block-device client depends on what the nook's kernel could offer, which
# is not knowable until one has been adopted. `nook doctor` names the right one.
command -v iscsiadm >/dev/null || command -v nbd-client >/dev/null ||
  dim "note: 'nook attach' needs open-iscsi or nbd — 'nook doctor' says which"

# ------------------------------------------------------------------------ nook

step "Installing nook into $SRC"
if [[ -d $SRC/.git ]]; then
  run git -C "$SRC" pull --quiet --ff-only
else
  run mkdir -p "$(dirname "$SRC")"
  run git clone --quiet "$REPO_URL" "$SRC"
fi
NOOK_FROM_BOOTSTRAP=1 run bash "$SRC/install.sh"

# ------------------------------------------------------------------ next steps

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    warn "$HOME/.local/bin is not on your PATH — add it to your shell profile:"
    warn '  export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

# Two commands, one on each machine. This is the second half of the second one:
# the box is already on the tailnet, so there is nothing left for a person to
# look up.
NOOK="$HOME/.local/bin/nook"
if [[ $DRY == 0 && -x $NOOK ]] && signed_in; then
  step "Looking for your nook"
  # shellcheck disable=SC2034  # read by the summary at the end
  if "$NOOK" adopt; then
    adopted=1
  else
    dim "nothing adopted yet — run 'nook adopt' once the box has finished its boot script"
  fi
fi

echo
bold "Done."
echo
if command -v tailscale >/dev/null && ! signed_in; then
  warn "still not on a tailnet — nook adopt will not reach anything until:"
  warn "  sudo tailscale up"
  echo
fi

# The two one-liners look alike and do opposite things. Anyone who ran this one
# on the box they meant to turn into a nook should hear about it here, not when
# `nook adopt` finds nothing to adopt.
if [[ -r /proc/device-tree/model ]] && grep -qai "raspberry pi" /proc/device-tree/model; then
  warn "this looks like a Raspberry Pi, and what you just installed is the client —"
  warn "the half you run on the machine you sit at, to reach a nook."
  warn ""
  warn "To make *this* box a nook, run the boot script on it instead:"
  warn "  curl -fsSL ${REPO_URL/github.com/raw.githubusercontent.com}/main/pi/boot.sh | bash"
  warn ""
  warn "Keeping the client here is fine — it is how this box would reach another one."
  echo
fi
echo "  on the box:  curl -fsSL https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh | bash"
echo "  here:        nook adopt <hostname>"
echo
dim "or do both from here: nook boot <hostname>"
dim "more than one box? adopt each, then: nook list / nook use <name>"
