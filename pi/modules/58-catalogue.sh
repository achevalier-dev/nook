# shellcheck shell=bash
# 58-catalogue — keep the box's copy of the catalogue current on its own.
#
# Daily, because it is one small tarball and a service added upstream is a
# service this box could be running. Nothing is installed or changed by it: it
# only refreshes the list of what could be.

install_bin nook-catalogue

cat >/etc/systemd/system/nook-catalogue.service <<'CONF'
[Unit]
Description=Refresh the nook's catalogue
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nook-catalogue --quiet
CONF

cat >/etc/systemd/system/nook-catalogue.timer <<'CONF'
[Unit]
Description=Refresh the nook's catalogue daily

[Timer]
OnBootSec=3min
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
CONF

systemctl daemon-reload
systemctl enable --now nook-catalogue.timer >/dev/null
note "catalogue refreshes itself daily"
