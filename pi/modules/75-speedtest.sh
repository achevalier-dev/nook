# shellcheck shell=bash
# 75-speedtest — the box can measure its own link, on demand or on a timer.
#
# The timer is off unless asked for: a speed test is the one reading here that
# costs real bandwidth to take, and a box on a metered connection should not be
# doing it four times a day because nobody said otherwise.

install_bin nook-speedtest

cat >/etc/systemd/system/nook-speedtest.service <<'CONF'
[Unit]
Description=Measure the nook's link
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nook-speedtest --quiet
CONF

cat >/etc/systemd/system/nook-speedtest.timer <<'CONF'
[Unit]
Description=Measure the nook's link periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
CONF

systemctl daemon-reload

if [[ ${NOOK_SPEEDTEST:-0} == 1 ]]; then
  systemctl enable --now nook-speedtest.timer >/dev/null
  note "link measured every 6 hours"
else
  systemctl disable --now nook-speedtest.timer >/dev/null 2>&1 || true
  note "speed test available on demand — nook speedtest"
fi
