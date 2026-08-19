#!/usr/bin/env bash
# nook-api answers the index page's manage controls, and it is the one thing in
# this repository that takes input from a browser. These are the ways it stops
# being safe, and the ways it stops working.
#
# No box and no docker: the catalogue is a directory in /tmp and docker is a
# stub that records what it was asked to do.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
API=$PWD/pi/bin/nook-api

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

data=$root/data
mkdir -p "$data/catalogue/jellyfin" "$data/catalogue/home" "$data/stacks/home" "$data/apps"

cat >"$data/catalogue/jellyfin/nook.json" <<'JSON'
{"name":"jellyfin","summary":"Films and television","port":8096,"library":"files/films"}
JSON
printf 'services:\n  jellyfin:\n    image: jellyfin/jellyfin\n' >"$data/catalogue/jellyfin/compose.yaml"
cat >"$data/catalogue/home/nook.json" <<'JSON'
{"name":"home","summary":"One page listing everything on this box","port":8880}
JSON
printf 'services:\n  home:\n    image: nginx:alpine\n' >"$data/catalogue/home/compose.yaml"
printf 'server { listen 80; }\n' >"$data/catalogue/home/default.conf.template"
printf 'HOME_PORT=80\n' >"$data/stacks/home/.env"

cat >"$root/nook.conf" <<CONF
NOOK_NAME=testbox
NOOK_DATA=$data
NOOK_USER=$(id -un)
CONF

# Stubs on PATH ahead of anything real. docker records its arguments rather
# than running; nothing here may reach a daemon.
mkdir -p "$root/bin"
cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  "compose ls --format json") echo '[{"Name":"home"}]' ;;
esac
exit 0
STUB
for stub in tailscale timedatectl ss; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/$stub"
done
chmod +x "$root/bin"/*

bad=0
check() { # <label> <expected substring> <actual>
  if [[ $3 == *"$2"* ]]; then return 0; fi
  echo "api: $1" >&2
  echo "  expected to contain: $2" >&2
  echo "  got: $(head -c 400 <<<"$3")" >&2
  bad=1
}

request() { # <request line> — the response, headers and all
  printf '%s HTTP/1.1\r\nHost: nook\r\n\r\n' "$1" |
    NOOK_CONF=$root/nook.conf PATH="$root/bin:$PATH" TMPDIR=$root bash "$API"
}

# ── what it says ─────────────────────────────────────────────────────────────
listing=$(request "GET /services")
check "the listing is not JSON over HTTP" "200 OK" "$listing"
body=${listing#*$'\r\n\r\n'}
python3 -c "import json,sys; json.loads(sys.argv[1])" "$body" ||
  { echo "api: the listing is not valid JSON" >&2; bad=1; }
check "the catalogue is missing jellyfin" '"name":"jellyfin"' "$body"
check "an uninstalled service is reported as installed" '"port":8096,"installed":false,"running":false' "$body"
check "the running index is not reported as running" '"running":true' "$body"
check "the index port comes from the stack, not the catalogue" '"port":80,' "$body"

# ── what it refuses ──────────────────────────────────────────────────────────
check "a path outside the catalogue is not refused" "404" "$(request 'POST /services/../../etc/install')"
check "an unknown service is not refused" "404" "$(request 'POST /services/nothing/install')"
check "an unknown endpoint is not refused" "404" "$(request 'GET /etc/passwd')"
check "an unknown endpoint is not refused" "404" "$(request 'POST /services/jellyfin/exec')"
check "installing something already installed is not refused" "409" "$(request 'POST /services/home/install')"
check "updating something not installed is not refused" "409" "$(request 'POST /services/jellyfin/update')"
check "removing the index page from itself is not refused" "409" "$(request 'POST /services/home/remove')"
[[ -f $root/docker.log ]] && grep -qE 'up -d|down' "$root/docker.log" &&
  { echo "api: a refused request still reached docker" >&2; bad=1; }

# ── what it does ─────────────────────────────────────────────────────────────
: >"$root/docker.log"
added=$(request "POST /services/jellyfin/install")
check "installing did not report success" '"ok":true' "$added"
[[ -f $data/stacks/jellyfin/compose.yaml ]] ||
  { echo "api: the compose file was never written to the stack" >&2; bad=1; }
[[ -f $data/stacks/jellyfin/.env ]] ||
  { echo "api: the stack has no .env — the compose file expands to nothing" >&2; bad=1; }
[[ -f $data/stacks/jellyfin/nook.json ]] &&
  { echo "api: the catalogue metadata was copied into the stack" >&2; bad=1; }
[[ -d $data/apps/jellyfin ]] ||
  { echo "api: the data directory was left for docker to create as root" >&2; bad=1; }
[[ -d $data/files/films ]] ||
  { echo "api: the declared library directory was never made" >&2; bad=1; }
check "install did not bring the stack up" "up -d" "$(cat "$root/docker.log")"

: >"$root/docker.log"
check "update did not report success" '"ok":true' "$(request 'POST /services/jellyfin/update')"
check "update did not pull" "pull" "$(cat "$root/docker.log")"

: >"$root/docker.log"
check "remove did not report success" '"ok":true' "$(request 'POST /services/jellyfin/remove')"
check "remove did not take the stack down" "down" "$(cat "$root/docker.log")"
[[ -d $data/stacks/jellyfin ]] &&
  { echo "api: the stack directory survived a remove" >&2; bad=1; }
[[ -d $data/apps/jellyfin ]] ||
  { echo "api: remove deleted the service's data — it must not" >&2; bad=1; }

# ── what the index page mounts it as ─────────────────────────────────────────
grep -q 'proxy_pass http://${NOOK_TS_IP}:${NOOK_API_PORT}/' services/home/default.conf.template ||
  { echo "api: the index page no longer proxies to the manage controls" >&2; bad=1; }
grep -q 'ListenStream=\$NOOK_TS_IP:\$NOOK_API_PORT' pi/modules/55-api.sh ||
  { echo "api: the socket is not bound to the tailnet address" >&2; bad=1; }

[[ $bad == 0 ]] && echo "api: lists, refuses what it should, and installs, updates and removes"
exit $bad
