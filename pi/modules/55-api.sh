# shellcheck shell=bash
# 55-api — the manage controls on the index page: add, update and remove a
# service from a browser, with no laptop and no CLI involved.
#
# Two pieces. A copy of the catalogue on the box, because a box that cannot read
# a compose file cannot install one. And a socket unit that starts one bash
# process per request — no daemon, nothing listening but systemd, and nothing
# running at all when nobody has the page open.
#
# The socket is bound to this box's tailnet address, and a request can only name
# a directory that already exists in the catalogue. On a box with no tailnet
# there is nothing safe to bind to, so the module stands down.

NOOK_API_PORT=${NOOK_API_PORT:-8881}

if [[ ${NOOK_MANAGE:-1} != 1 ]]; then
  systemctl disable --now nook-api.socket >/dev/null 2>&1 || true
  note "the index page is read-only — no manage controls"
  return 0
fi

if [[ -z ${NOOK_TS_IP:-} ]]; then
  systemctl disable --now nook-api.socket >/dev/null 2>&1 || true
  warn "no tailnet address yet — the index page stays read-only"
  return 0
fi

install_bin nook-api

# The catalogue, on the box. A checkout wins, exactly like the modules: that is
# what makes `git clone && sudo pi/boot.sh` a working dev loop. Otherwise the
# repository tarball, which is the same source the one-liner came from.
sync_catalogue() {
  local dest=$NOOK_DATA/catalogue src tmp
  src="$(dirname -- "${BASH_SOURCE[0]}")/../../services"

  install -d -o "$NOOK_USER" -g "$NOOK_USER" "$dest"

  # Swapped, not merged: a service dropped upstream has to disappear here too,
  # or the box keeps offering something the catalogue no longer vouches for.
  swap_in() { # <directory holding the new catalogue>
    rm -rf "$dest.new" "$dest.old"
    cp -a "$1" "$dest.new"
    chown -R "$NOOK_USER:$NOOK_USER" "$dest.new"
    mv "$dest" "$dest.old" 2>/dev/null || true
    mv "$dest.new" "$dest"
    rm -rf "$dest.old"
  }

  if [[ -d $src ]]; then
    swap_in "$src"
    note "catalogue from the checkout ($(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l) services)"
    return 0
  fi

  tmp=$(mktemp -d)
  if curl -fsSL "$NOOK_REPO_TARBALL" |
    tar -xz -C "$tmp" --strip-components=2 --wildcards '*/services/*' 2>/dev/null &&
    [[ -n $(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print -quit) ]]; then
    swap_in "$tmp"
    note "catalogue fetched ($(find "$dest" -mindepth 1 -maxdepth 1 -type d | wc -l) services)"
  else
    warn "could not fetch the catalogue — the page can still update and remove"
  fi
  rm -rf "$tmp"
}

sync_catalogue

# Publish the icons that came with it, so the page has them before the daily
# catalogue timer first fires.
install -d -o "$NOOK_USER" -g "$NOOK_USER" "$NOOK_DATA/www/icons"
for art in "$NOOK_DATA/catalogue"/*/icon.*; do
  [[ -f $art ]] || continue
  install -m 644 -o "$NOOK_USER" -g "$NOOK_USER" \
    "$art" "$NOOK_DATA/www/icons/$(basename "$(dirname "$art")").${art##*.}"
done

# Accept=yes means one instance of the service per connection, with the socket
# on its stdin and stdout. A request that is a docker pull can take minutes, so
# the instance is allowed to.
cat >/etc/systemd/system/nook-api.socket <<CONF
[Unit]
Description=Manage controls for the nook's index page

[Socket]
ListenStream=$NOOK_TS_IP:$NOOK_API_PORT
Accept=yes

[Install]
WantedBy=sockets.target
CONF

cat >/etc/systemd/system/nook-api@.service <<'CONF'
[Unit]
Description=One request to the nook index page's manage controls

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nook-api
StandardInput=socket
StandardOutput=socket
StandardError=journal
TimeoutStartSec=900
CONF

systemctl daemon-reload
systemctl enable --now nook-api.socket >/dev/null
note "the index page can add, update and remove services — $NOOK_TS_IP:$NOOK_API_PORT"
