# shellcheck shell=bash
# Three separate things go out of date, and conflating them is how one of them
# gets forgotten:
#
#   the nook command here   `nook update` — git, and re-linking
#   the box's own setup     re-running its boot script
#   the services on it      newer images, restarted only if they changed
#
# `nook upgrade` does the last two and says when the first is behind. The OS is
# nobody's business here: unattended-upgrades handles its security updates.

cmd_upgrade() {
  load_config

  case ${1:-} in
    --auto)
      remote sudo systemctl enable --now nook-upgrade.timer
      echo "services upgrade themselves weekly on $NOOK"
      remote systemctl list-timers nook-upgrade.timer --no-pager 2>/dev/null | sed -n 2p
      return 0
      ;;
    --no-auto)
      remote sudo systemctl disable --now nook-upgrade.timer
      echo "automatic upgrades are off on $NOOK — nook upgrade still works by hand"
      return 0
      ;;
    --box)
      upgrade_box
      return 0
      ;;
    "" | --services) ;;
    *) die "usage: nook upgrade [--services | --box | --auto | --no-auto]" ;;
  esac

  log "upgrading services on $NOOK"
  remote nook-upgrade

  # Said, not done: pulling the client mid-command would replace the code that
  # is running.
  if [[ -d $ROOT/.git ]] && command -v git >/dev/null; then
    git -C "$ROOT" fetch --quiet 2>/dev/null || true
    local behind
    behind=$(git -C "$ROOT" rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)
    ((behind > 0)) && echo "
  nook itself is $behind commits behind — nook update"
  fi
  return 0
}

# Re-running the boot script is how a box picks up anything new in nook's own
# setup. It is idempotent by design, so this is safe to do whenever.
upgrade_box() {
  local url=${NOOK_BOOT_URL:-https://raw.githubusercontent.com/achevalier-dev/nook/main/pi/boot.sh}
  log "re-running the boot script on $NOOK"
  ssh -t "$NOOK_HOST" "curl -fsSL $url | bash"
  echo
  echo "re-adopt if its transport or paths changed:  nook adopt"
}
