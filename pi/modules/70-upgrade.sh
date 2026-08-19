# shellcheck shell=bash
# 70-upgrade — a weekly timer that pulls newer images for the stacks on this box
# and restarts only the ones that changed.
#
# On by default, because a home server nobody logs into is exactly the machine
# that ends up months behind. --no-auto-upgrade turns it off, and it never
# touches the OS: that is unattended-upgrades' job, set up in 10-base.

install_bin nook-upgrade

if [[ ${NOOK_AUTO_UPGRADE:-1} != 1 ]]; then
  systemctl disable --now nook-upgrade.timer >/dev/null 2>&1 || true
  note "automatic service upgrades are off"
  return 0
fi

cat >/etc/systemd/system/nook-upgrade.service <<'CONF'
[Unit]
Description=Pull newer images for the nook's services
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nook-upgrade --quiet
CONF

cat >/etc/systemd/system/nook-upgrade.timer <<'CONF'
[Unit]
Description=Weekly service upgrades for the nook

[Timer]
OnCalendar=Sun 04:00
# An hour of jitter, so a tailnet full of nooks does not hit the registry at the
# same second, and Persistent so a box that was off still catches up.
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
CONF

systemctl daemon-reload
systemctl enable --now nook-upgrade.timer >/dev/null
note "services upgrade themselves weekly — nook-upgrade.timer"
