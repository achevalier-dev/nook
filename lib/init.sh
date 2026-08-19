# shellcheck shell=bash
# Choosing between nooks. A Raspberry Pi and a mini PC are two entries under
# ~/.nook, and every other command talks to whichever one is selected.

cmd_use() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: nook use <name> — nook list"
  [[ -f $(nook_dir "$name")/config ]] || die "unknown nook '$name' — nook list"
  printf '%s\n' "$name" >"$NOOK_HOME/default"
  echo "default nook: $name"
}

cmd_list() {
  migrate_single_nook
  local default name host transport marker
  default=$(default_nook || echo "")

  local found=0
  while read -r name; do
    [[ -n $name ]] || continue
    found=1
    # Read the fields out rather than sourcing: a `nook list` should not be able
    # to run whatever happens to be in a config file.
    host=$(sed -n 's/^NOOK_HOST=//p' "$(nook_dir "$name")/config" | head -n1)
    transport=$(sed -n 's/^NOOK_TRANSPORT=//p' "$(nook_dir "$name")/config" | head -n1)
    marker=" "
    [[ $name == "$default" ]] && marker="*"
    printf '%s %-16s %-24s %s\n' "$marker" "$name" "${host:-?}" "${transport:-none}"
  done < <(nooks)

  ((found)) || echo "no nooks adopted here — run: nook adopt <host>"
}

# Forgets a nook on this machine only. Nothing is touched on the box itself,
# which is the whole point: adopting it again is one command.
cmd_forget() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: nook forget <name>"
  local dir
  dir=$(nook_dir "$name")
  [[ -d $dir ]] || die "unknown nook '$name' — nook list"

  systemctl --user disable --now "nook-mount@$name.service" >/dev/null 2>&1 || true
  command -v docker >/dev/null && docker context rm "nook-$name" >/dev/null 2>&1 || true
  rm -rf "$dir"

  # The default has to point at something that still exists, or every later
  # command dies on a name nobody can see any more.
  if [[ $(default_nook || echo "") == "$name" ]]; then
    local next
    next=$(nooks | head -n1)
    if [[ -n $next ]]; then
      printf '%s\n' "$next" >"$NOOK_HOME/default"
      echo "default nook is now $next"
    else
      rm -f "$NOOK_HOME/default"
    fi
  fi
  write_ssh_config
  echo "forgot $name"
}

# nook update — pull the checkout this command runs from and re-link. Without
# it, a fix means remembering where bootstrap put the clone, which is a thing
# nobody should have to know.
# The client half of what the box already does for its services: a machine
# nobody thinks about is exactly the one that ends up months behind, and a stale
# CLI here looks like broken features rather than an old version — menu rows
# vanish, `nook services` is an unknown command.
update_auto() { # <root> on|off
  local root=$1 want=$2 unit_dir=$HOME/.config/systemd/user
  command -v systemctl >/dev/null ||
    die "no systemd here — schedule 'nook update --quiet' with whatever this machine uses"

  if [[ $want == off ]]; then
    systemctl --user disable --now nook-update.timer >/dev/null 2>&1 || true
    echo "automatic updates are off — nook update still works by hand"
    return 0
  fi

  mkdir -p "$unit_dir"
  cp -f "$root/systemd/nook-update.service" "$root/systemd/nook-update.timer" "$unit_dir/"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now nook-update.timer >/dev/null ||
    die "could not enable nook-update.timer — is the user manager running?"
  echo "nook updates itself daily"
  systemctl --user list-timers nook-update.timer --no-pager 2>/dev/null | sed -n 2p
}

cmd_update() {
  local root=$1 quiet=0
  shift

  case ${1:-} in
    --auto) update_auto "$root" on; return 0 ;;
    --no-auto) update_auto "$root" off; return 0 ;;
    --quiet) quiet=1 ;;
    "") ;;
    *) die "usage: nook update [--quiet | --auto | --no-auto]" ;;
  esac

  [[ -d $root/.git ]] || die "$root is not a git checkout — re-run the bootstrap to update"
  need git

  local before after
  before=$(git -C "$root" rev-parse --short HEAD)
  # --ff-only is the whole safety story: a checkout with local work, or one that
  # has diverged, is refused rather than rewritten. Under the timer that refusal
  # goes to the journal and `nook doctor` reports the machine as behind, which is
  # better than a daily notification nobody can act on.
  if ! git -C "$root" pull --quiet --ff-only 2>/dev/null; then
    ((quiet)) && return 0
    die "could not fast-forward $root — is it modified?"
  fi
  after=$(git -C "$root" rev-parse --short HEAD)

  if [[ $before == "$after" ]]; then
    ((quiet)) || echo "already up to date ($after)"
    return 0
  fi

  # install.sh is where the symlinks, the unit and the skill come from, and a
  # new version may add to them.
  NOOK_FROM_BOOTSTRAP=1 bash "$root/install.sh" >/dev/null

  if ((quiet)); then
    # One line, because this arrives unasked while somebody is doing something
    # else: a desktop notification, and the same sentence in the journal for
    # whoever reads `systemctl --user status nook-update` afterwards. What
    # changed is in `git log`, and `nook doctor` names the version.
    notify "nook updated to $after — $(git -C "$root" rev-list --count "$before..$after") new commits"
    return 0
  fi

  echo "updated $before -> $after"
  git -C "$root" log --oneline "$before..$after" | sed 's/^/  /'
  echo
  echo "re-adopt to pick up anything that changed in how boxes are recorded:"
  echo "  nook adopt"
}
