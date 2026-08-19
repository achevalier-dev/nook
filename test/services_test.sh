#!/usr/bin/env bash
# The catalogue is a promise that `nook install <name>` works. These are the
# ways it silently stops being one.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bad=0
declare -A seen_port

for dir in services/*/; do
  name=$(basename "$dir")

  for f in nook.json compose.yaml; do
    [[ -f $dir$f ]] || { echo "services/$name has no $f" >&2; bad=1; }
  done
  [[ -f $dir/nook.json ]] || continue

  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$dir/nook.json" ||
    { echo "services/$name/nook.json is not valid JSON" >&2; bad=1; continue; }

  declared=$(jq -r '.name' "$dir/nook.json")
  [[ $declared == "$name" ]] ||
    { echo "services/$name calls itself '$declared'" >&2; bad=1; }

  jq -e '.summary | length > 0' "$dir/nook.json" >/dev/null ||
    { echo "services/$name has no summary — nook services would print a blank" >&2; bad=1; }

  # The catalogue groups by this; without one a service lands under "other".
  jq -e '.category | length > 0' "$dir/nook.json" >/dev/null ||
    { echo "services/$name has no category — it would be filed under other" >&2; bad=1; }

  # Two services on one port means the second one to start just fails.
  port=$(jq -r '.port // empty' "$dir/nook.json")
  if [[ -n $port ]]; then
    if [[ -n ${seen_port[$port]:-} ]]; then
      echo "services/$name and services/${seen_port[$port]} both want port $port" >&2
      bad=1
    fi
    seen_port[$port]=$name
    # A host-network service has no ports section to publish through.
    if [[ $(jq -r '.host_network // false' "$dir/nook.json") != true ]] &&
      ! grep -q ':\${[A-Z_]*PORT' "$dir/compose.yaml"; then
      grep -q ":$port:" "$dir/compose.yaml" ||
        { echo "services/$name says port $port but its compose file does not publish it" >&2; bad=1; }
    fi
  fi

  # 0.0.0.0 on a box that travels is how a home server ends up on café wifi.
  if grep -qE '^\s*-\s*"[0-9]+:[0-9]+"' "$dir/compose.yaml"; then
    echo "services/$name publishes a port on every interface — bind \${NOOK_TS_IP}" >&2
    bad=1
  fi

  # Data outside $NOOK_DATA is data that no backup of the nook will catch. The
  # host path is everything before the first colon.
  while read -r host_path; do
    case $host_path in
      '${NOOK_DATA}'* | /var/run/docker.sock | /run/dbus | /dev/*) ;;
      *) echo "services/$name mounts $host_path, which is outside \$NOOK_DATA" >&2; bad=1 ;;
    esac
  done < <(sed -n 's/^[[:space:]]*-[[:space:]]*\([/$][^:]*\):.*/\1/p' "$dir/compose.yaml")
done

[[ $bad == 0 ]] && echo "services: $(ls -d services/*/ | wc -l) catalogued, ports unique, nothing on 0.0.0.0"
exit $bad
