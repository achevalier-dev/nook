# 10-base — hostname, packages, and the housekeeping that keeps a headless box
# from rotting: unattended security updates and a clock that survives a reboot.
#
# Sourced by boot.sh with set -euo pipefail already in effect. Use `return`,
# never `exit`: an exit here would take the whole run down mid-module.

export DEBIAN_FRONTEND=noninteractive

# A Pi that has just been imaged is usually already running something that holds
# the apt lock — unattended-upgrades fires on first boot. apt can wait for it
# itself, which beats failing on a race the user cannot see.
APT=(apt-get -o DPkg::Lock::Timeout=300 -qq)

# apt refuses to do anything at all while a previous install is half-finished,
# and the error it prints names the fix without applying it. This is that fix:
# it only completes configuration of packages that are already unpacked, so
# there is nothing here to lose, and it is a no-op when nothing is pending.
if [[ -n $(dpkg --audit 2>/dev/null) ]]; then
  warn "a previous package install was interrupted — finishing it before going on"
  if ! dpkg --configure -a; then
    warn "dpkg could not finish it. Fix that first, then re-run this script:"
    warn "    sudo dpkg --configure -a"
    return 1
  fi
fi

if [[ $(hostname) != "$NOOK_NAME" ]]; then
  hostnamectl set-hostname "$NOOK_NAME"
  # Debian resolves the hostname through /etc/hosts, and sudo warns loudly on
  # every single call if it cannot. Rewriting the 127.0.1.1 line is the fix.
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NOOK_NAME/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$NOOK_NAME" >>/etc/hosts
  fi
  note "hostname set to $NOOK_NAME"
fi

# apt-get update is the slow part of a re-run, so only pay for it once a day.
stamp=$NOOK_STATE/apt-updated
if [[ ! -f $stamp ]] || [[ $(find "$stamp" -mtime +1 -print -quit) ]]; then
  "${APT[@]}" update
  touch "$stamp"
fi

PACKAGES=(ca-certificates curl git rsync jq gdisk parted unattended-upgrades)
missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
  note "installing ${missing[*]}"
  "${APT[@]}" install -y "${missing[@]}"
fi

# Security updates only, applied automatically. A box you reach twice a year is
# a box that never gets patched by hand.
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

systemctl enable --now ssh >/dev/null 2>&1 || true

# A Pi has no RTC. Without NTP the clock starts in 1970 on every boot, which
# breaks TLS, breaks Tailscale's key checks, and makes logs useless.
timedatectl set-ntp true 2>/dev/null || true
