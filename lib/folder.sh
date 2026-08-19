# shellcheck shell=bash
# The shared lane: /mnt/nook/files over SFTP, mounted at ~/nook. Any number of
# machines can hold it at once, and containers on the nook see the same files.

cmd_mount() {
  load_config
  need sshfs
  if mountpoint -q "$NOOK_MOUNT"; then
    echo "already mounted at $NOOK_MOUNT"
    return 0
  fi
  mkdir -p "$NOOK_MOUNT"
  # The unit carries the reconnect options and survives a suspend; the direct
  # call is the fallback for a machine where install.sh never ran.
  systemctl --user start "nook-mount@$NOOK.service" 2>/dev/null ||
    sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user \
      "$NOOK_HOST:$NOOK_DATA/files" "$NOOK_MOUNT"
  notify "mounted at $NOOK_MOUNT"
}

cmd_umount() {
  load_config
  systemctl --user stop "nook-mount@$NOOK.service" 2>/dev/null || true
  if mountpoint -q "$NOOK_MOUNT"; then
    # -z, because the usual reason for unmounting by hand is that the mount went
    # stale and a plain fusermount3 -u would block on it too.
    fusermount3 -uz "$NOOK_MOUNT"
  fi
  notify "unmounted $NOOK_MOUNT"
}

# rsync rather than the mount: a big file over sshfs pays FUSE round trips per
# block, and --partial means a dropped link resumes instead of starting over.
cmd_push() {
  load_config
  [[ ${1:-} ]] || die "usage: nook push <src> [dest]"
  rsync -a --info=progress2 --partial "$1" "$NOOK_HOST:$NOOK_DATA/${2:-files/}"
}

cmd_pull() {
  load_config
  [[ ${1:-} ]] || die "usage: nook pull <src> [dest]"
  rsync -a --info=progress2 --partial "$NOOK_HOST:$NOOK_DATA/$1" "${2:-.}"
}

cmd_code() {
  load_config
  need code "VS Code — otherwise: nook ssh"
  code --remote "ssh-remote+$NOOK_HOST" "${1:-$NOOK_DATA/files}"
}
