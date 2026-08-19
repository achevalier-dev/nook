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

# Pushed to the box and deleted again afterwards; the name is what appears on
# screen, so it says what somebody would actually be moving.
DEMO_FILE=/tmp/nook-demo/holiday-2026.mkv
DEMO_REMOTE=/mnt/nook/files/media/holiday-2026.mkv

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
  # The arc is: the box, then the shared folder, then the drive, then health.
  # The drive is the half nothing else does, so it gets three of the eight.
  SEQUENCE=(
    # Whatever the last run left behind, the recording starts from a box with
    # its drive free and its folder unmounted.
    "hide:eject"
    "show:status"
    "hide:umount"
    "show:mount"
    "show:push $DEMO_FILE media/"
    "show:attach"
    "show:disk"
    "show:eject"
    "show:speedtest --last"
    "show:doctor"
  )
  # Big enough that rsync reports a real rate — a 43-byte file measures nothing
  # and prints 0.00kB/s, which reads as broken rather than fast.
  mkdir -p "$(dirname "$DEMO_FILE")"
  head -c 6000000 /dev/urandom >"$DEMO_FILE"
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
    -e "s/\b$(id -un)\b/you/g" \
    -e "s/\b$(hostname)\b/thismachine/g"
}

# One JSON object per line, assembled into an array at the end. Writing the
# commas by hand means a command that dies mid-run leaves a file that is not
# JSON at all, and the committed transcript is what the GIF is drawn from.
out=demo/transcript.json
: >"$out.tmp"

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
  jq -nc --arg cmd "nook $cmd" --arg body "$body" '{command: $cmd, output: $body}' >>"$out.tmp"
done

jq -s . "$out.tmp" >"$out"
rm -f "$out.tmp"
rm -rf /tmp/nook-demo
# The recording is not a reason to leave a six-megabyte file on somebody's box.
((REAL)) && ./bin/nook ssh rm -f "$DEMO_REMOTE" >/dev/null 2>&1 || true
if ((REAL)); then source=" from a real nook"; else source=", staged"; fi
echo "wrote $out ($(jq length "$out") commands$source)"
