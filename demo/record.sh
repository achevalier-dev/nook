#!/usr/bin/env bash
# Runs the demo sequence and writes what it printed to demo/transcript.json.
# The renderer draws that file and nothing else, so the GIF cannot drift from
# what the code actually says.
#
#   ./demo/record.sh          against demo/fake-nook — no box needed
#   ./demo/record.sh --real   against a nook you have actually adopted
#
# Real output is sanitised on the way out: tailnet addresses and the machine
# name of whoever recorded it are not part of the demonstration.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REAL=0
[[ ${1:-} == --real ]] && REAL=1

if ((REAL)); then
  RUN=(./bin/nook)
  export HOME=$HOME
else
  DEMO_STATE=$(mktemp -d)
  export DEMO_STATE
  # A generic home, so the recording does not show whoever made it.
  export HOME=/home/you
  RUN=(./demo/fake-nook)
  trap 'rm -rf "$DEMO_STATE"' EXIT
fi

# Each entry is either a command to show and run, or a hidden one that only
# moves the demo's state along.
if ((REAL)); then
  SEQUENCE=(
    "show:list"
    "show:status"
    "hide:umount"
    "show:mount"
    "show:push /tmp/nook-demo-file.txt"
    "show:vault list"
    "show:disk"
    "show:doctor"
  )
  printf 'a file from the machine you are sitting at\n' >/tmp/nook-demo-file.txt
else
  SEQUENCE=(
    "show:adopt pi"
    "show:adopt thinkcentre"
    "show:list"
    "show:status --all"
    "show:use thinkcentre"
    "show:attach"
    "show:eject"
    "hide:hold thinkcentre"
    "show:attach"
    "hide:release thinkcentre"
    "show:doctor --all"
  )
fi

# Tailnet addresses and the recorder's own hostname are not part of what is
# being shown, and a public GIF is a poor place to publish either.
sanitise() {
  # rsync redraws its progress line with carriage returns; captured to a file
  # that becomes one unreadable line, so keep only what was on screen last.
  sed -E \
    -e 's/.*\r//' \
    -e 's/100\.[0-9]+\.[0-9]+\.[0-9]+/100.x.y.z/g' \
    -e "s#/home/$(id -un)#/home/you#g" \
    -e "s/\b$(hostname)\b/thismachine/g"
}

out=demo/transcript.json
: >"$out.tmp"
echo "[" >>"$out.tmp"
first=1

for entry in "${SEQUENCE[@]}"; do
  mode=${entry%%:*}
  cmd=${entry#*:}

  if [[ $mode == hide ]]; then
    # shellcheck disable=SC2086  # the sequence carries its own word splitting
    "${RUN[@]}" $cmd >/dev/null 2>&1 || true
    continue
  fi

  # Failure is part of the demo — the refusal is the point of one of these.
  # shellcheck disable=SC2086
  body=$("${RUN[@]}" $cmd 2>&1 | sanitise || true)
  [[ $first == 1 ]] || echo "," >>"$out.tmp"
  first=0
  jq -n --arg cmd "nook $cmd" --arg body "$body" '{command: $cmd, output: $body}' >>"$out.tmp"
done

echo "]" >>"$out.tmp"
jq . "$out.tmp" >"$out"
rm -f "$out.tmp" /tmp/nook-demo-file.txt
if ((REAL)); then source=" from a real nook"; else source=", staged"; fi
echo "wrote $out ($(jq length "$out") commands$source)"
