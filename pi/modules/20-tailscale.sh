# 20-tailscale — reachable from anywhere, with nothing secret to copy.
#
# No auth key on purpose. `tailscale up` prints a URL and a QR code; you open it
# in a browser where you are already signed in, and that is the whole pairing
# step. A key pasted onto a command line ends up in shell history and in
# /proc/*/cmdline, and buys nothing here.
#
# --ssh is the other half: it authenticates SSH by tailnet identity, so no
# keys are generated, copied, or authorised anywhere.

if ! command -v tailscale >/dev/null; then
  note "installing tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled >/dev/null

if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
  note "already on the tailnet as $(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
else
  cat <<'PROMPT'

    Open the link below (or scan the QR) on a device where you are already
    signed in to Tailscale. Nothing to copy, nothing to paste back.

PROMPT
  # Foreground on purpose: the run should block here until the box is actually
  # on the tailnet, because every module after this one assumes it is.
  tailscale up --ssh --qr --hostname "$NOOK_NAME" --accept-dns=false
fi

NOOK_TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
[[ -n ${NOOK_TS_IP:-} ]] || { warn "tailscale is up but has no IPv4 address yet"; return 0; }
note "tailnet address $NOOK_TS_IP"

# MagicDNS is what turns `ssh nook` into a thing that works from any of your
# machines. It is a tailnet-wide setting, so all we can do is say when it is off.
tailscale status --json | jq -e '.MagicDNSSuffix != ""' >/dev/null ||
  warn "MagicDNS is off for this tailnet — enable it in the admin console or you will be typing IP addresses"
