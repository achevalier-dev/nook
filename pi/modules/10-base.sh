# 10-base — hostname, packages, and the housekeeping that keeps a headless box
# from rotting: unattended security updates and a clock that survives a reboot.
#
# Sourced by boot.sh with set -euo pipefail already in effect. Use `return`,
# never `exit`: an exit here would take the whole run down mid-module.

export DEBIAN_FRONTEND=noninteractive

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
  apt-get update -qq
  touch "$stamp"
fi

PACKAGES=(ca-certificates curl git rsync jq gdisk parted unattended-upgrades)
missing=()
for pkg in "${PACKAGES[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
  note "installing ${missing[*]}"
  apt-get install -y -qq "${missing[@]}"
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
