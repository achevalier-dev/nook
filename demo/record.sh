#!/usr/bin/env bash
# Runs the demo sequence through demo/fake-nook and writes what it printed to
# demo/transcript.json. The renderer draws that file and nothing else, so the
# GIF cannot drift from what the code actually says.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
DEMO_STATE=$(mktemp -d)
export DEMO_STATE
# A generic home, so the recording does not show whoever made it.
export HOME=/home/you
trap 'rm -rf "$DEMO_STATE"' EXIT

# Each entry is either a command to show and run, or a hidden one that only
# moves the demo's state along.
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

out=demo/transcript.json
: >"$out.tmp"
echo "[" >>"$out.tmp"
first=1

for entry in "${SEQUENCE[@]}"; do
  mode=${entry%%:*}
  cmd=${entry#*:}

  if [[ $mode == hide ]]; then
    ./demo/fake-nook $cmd >/dev/null 2>&1 || true
    continue
  fi

  # Failure is part of the demo — the refusal is the point of one of these.
  body=$(./demo/fake-nook $cmd 2>&1 || true)
  [[ $first == 1 ]] || echo "," >>"$out.tmp"
  first=0
  jq -n --arg cmd "nook $cmd" --arg body "$body" '{command: $cmd, output: $body}' >>"$out.tmp"
done

echo "]" >>"$out.tmp"
jq . "$out.tmp" >"$out"
rm -f "$out.tmp"
echo "wrote $out ($(jq length "$out") commands)"
