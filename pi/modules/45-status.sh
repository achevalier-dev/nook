# shellcheck shell=bash
# 45-status — write the box's vitals somewhere the index page can read them.
#
# A page that only lists links is a bookmark folder. The temperature of a
# machine in a cupboard is a physical fact about it, and showing it is the
# difference between a directory and something that feels switched on.

install_bin nook-info

cat >/etc/systemd/system/nook-status.service <<CONF
[Unit]
Description=Write the nook's vitals for its index page
After=docker.service

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p $NOOK_DATA/www
# Written beside, moved into place: a page that fetches it mid-write would
# otherwise get half a JSON object.
ExecStart=/bin/sh -c '/usr/local/bin/nook-info > $NOOK_DATA/www/.status.json && mv $NOOK_DATA/www/.status.json $NOOK_DATA/www/status.json'
CONF

cat >/etc/systemd/system/nook-status.timer <<'CONF'
[Unit]
Description=Keep the nook's vitals fresh

[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
AccuracySec=5s

[Install]
WantedBy=timers.target
CONF

systemctl daemon-reload
systemctl enable --now nook-status.timer >/dev/null
note "vitals refresh every 20s for the index page"
