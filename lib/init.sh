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
