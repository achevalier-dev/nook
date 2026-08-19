#!/usr/bin/env bash
# Runs one real Claude Code session against the nook skill and writes what it
# did to demo/skill-transcript.json. The renderer draws that file and nothing
# else, so the GIF cannot show the skill behaving better than it does.
#
#   ./demo/record-skill.sh                 the question below
#   ./demo/record-skill.sh "some other question"
#
# The question is the one the skill exists for. A block device belongs to one
# machine at a time, and somebody who does not know that is one command away
# from a filesystem two machines have written to.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROMPT=${1:-"can I attach the nook drive on this machine and on my desktop at the same time, so both can write to it?"}

command -v claude >/dev/null || {
  echo "claude not on PATH — this records a real session, not a mock" >&2
  exit 1
}

raw=$(mktemp)
trap 'rm -f "$raw"' EXIT

# Whatever plugins and hooks the recorder runs are switched off for the length
# of the session, for the same reason the transcript is sanitised afterwards:
# what is being shown is the skill, not the voice somebody's own setup gives it.
plugins=$(jq -c '(.enabledPlugins // {}) | map_values(false)' \
  ~/.claude/settings.json 2>/dev/null || echo '{}')

# Read-only tools: a recording is a poor place to find out what a prompt does
# to somebody's box.
claude -p "$PROMPT" \
  --output-format stream-json --verbose \
  --settings "{\"hooks\": {}, \"enabledPlugins\": $plugins}" \
  --allowedTools "Bash,Skill,Read" >"$raw"

# Tailnet addresses and the recorder's own names are not part of what is being
# shown, and a public GIF is a poor place to publish either.
sanitise() {
  sed -E \
    -e 's/100\.[0-9]+\.[0-9]+\.[0-9]+/100.x.y.z/g' \
    -e "s/\b$(id -un)\b/you/g" \
    -e "s/\b$(hostname)\b/thismachine/g"
}

out=demo/skill-transcript.json
jq -s --arg prompt "$PROMPT" '
  [{role: "user", text: $prompt}]
  + [ .[]
      | select(.type == "assistant")
      | .message.content[]
      | if .type == "tool_use" then
          {tool: .name, arg: (.input.command // .input.skill // .input.file_path // "")}
        elif .type == "text" and (.text | length > 0) then
          {role: "assistant", text: .text}
        else empty end ]
' "$raw" | sanitise >"$out"

echo "wrote $out ($(jq '[.[] | select(.tool)] | length' "$out") tool calls)"
