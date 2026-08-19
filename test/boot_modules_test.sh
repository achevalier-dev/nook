#!/usr/bin/env bash
# pi/boot.sh sources its modules rather than executing them, so a module that
# calls `exit` takes the whole run down halfway through. And a module on disk
# that is not in MODULES never runs at all, silently.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bad=0

listed=$(sed -n 's/^MODULES=(\(.*\))$/\1/p' pi/boot.sh | tr ' ' '\n' | sort)
[[ -n $listed ]] || { echo "no MODULES array found in pi/boot.sh" >&2; exit 1; }
on_disk=$(find pi/modules -name '*.sh' -exec basename {} .sh \; | sort)

diff <(echo "$listed") <(echo "$on_disk") >/dev/null || {
  echo "pi/boot.sh MODULES and pi/modules/ disagree:" >&2
  diff <(echo "$listed") <(echo "$on_disk") >&2 || true
  bad=1
}

for f in pi/modules/*.sh; do
  # `exit 0` inside a subshell or a heredoc is fine; a bare top-level one is not.
  grep -nE '^\s*exit\b' "$f" && {
    echo "$f calls exit at the top level — modules are sourced, use return" >&2
    bad=1
  }
done

# Modules run under `set -e` from boot.sh, where a bare `cond && action` guard
# that turns out false ends the run.
for f in pi/modules/*.sh pi/boot.sh; do
  grep -nE '^\s*\[\[[^]]*\]\] && \{' "$f" && {
    echo "$f uses a '[[ ]] && { }' guard — under set -e write it as an if" >&2
    bad=1
  }
done

# The drive is a preallocated image, and the one place it must never be created
# is the disk the box boots from — that fills the card and takes the whole box
# down, which is exactly what happened before this check existed.
grep -q 'NOOK_HAS_EXTERNAL' pi/modules/35-disk.sh || {
  echo "35-disk does not check for an external disk before creating the image" >&2
  bad=1
}
grep -q 'NOOK_HAS_EXTERNAL' pi/modules/30-storage.sh || {
  echo "30-storage never reports whether it found an external disk" >&2
  bad=1
}
# A failed fallocate leaves whatever it managed to reserve behind.
grep -A3 'fallocate -l' pi/modules/35-disk.sh | grep -q 'rm -f' || {
  echo "35-disk does not clean up a partial image when fallocate fails" >&2
  bad=1
}

# The drive, Samba and USB gadget are optional. A box without them is still
# worth adopting, so none of them may end the run — /etc/nook.conf is written
# last, and a box that never gets one cannot be adopted at all.
for f in pi/modules/35-disk.sh pi/modules/50-shares.sh pi/modules/60-usb-gadget.sh; do
  grep -nE '^\s*return [1-9]' "$f" && {
    echo "$f can end the whole run — an optional module must return 0" >&2
    bad=1
  }
done

# A Pi runs unattended-upgrades on first boot, so any apt call that does not
# wait for the lock is a coin flip on a freshly imaged card.
while IFS= read -r line; do
  grep -q 'DPkg::Lock::Timeout' <<<"$line" && continue
  grep -q 'APT\[@\]' <<<"$line" && continue
  echo "$line" >&2
  echo "  ^ apt-get without DPkg::Lock::Timeout — it will fail on a first boot" >&2
  bad=1
done < <(grep -n 'apt-get [a-z]' pi/modules/*.sh pi/boot.sh | grep -v ':[0-9]*:#' || true)

[[ $bad == 0 ]] && echo "boot: every module is listed, sourced-safe, set -e clean, and apt waits"
exit $bad
