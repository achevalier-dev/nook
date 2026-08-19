#!/usr/bin/env bash
# replace_block edits files nook does not own — ~/.ssh/config, smb.conf. It must
# insert once, replace in place on a re-run, and never disturb what is around it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NOOK_HOME=$(mktemp -d)
export NOOK_HOME
trap 'rm -rf "$NOOK_HOME"' EXIT

# shellcheck source=lib/common.sh
source lib/common.sh

file="$NOOK_HOME/config"
cat >"$file" <<'EOF'
Host something-else
	User someone
EOF

printf 'Host nook\n\tUser first\n' | replace_block "$file" "# >>> nook" "# <<< nook" prepend
grep -q "User first" "$file" || { echo "block was not inserted" >&2; exit 1; }
grep -q "Host something-else" "$file" || { echo "existing content was lost" >&2; exit 1; }
head -n1 "$file" | grep -q '^# >>> nook$' || { echo "prepend did not put the block on top" >&2; exit 1; }

printf 'Host nook\n\tUser second\n' | replace_block "$file" "# >>> nook" "# <<< nook" prepend
[[ $(grep -c '^# >>> nook$' "$file") == 1 ]] || { echo "re-running duplicated the block" >&2; exit 1; }
grep -q "User second" "$file" || { echo "block was not replaced" >&2; exit 1; }
grep -q "User first" "$file" && { echo "the old block survived" >&2; exit 1; }
grep -q "Host something-else" "$file" || { echo "existing content was lost on replace" >&2; exit 1; }

# Append mode goes to the bottom and leaves the head alone.
printf 'appended\n' | replace_block "$file" "# >>> other" "# <<< other"
tail -n2 "$file" | head -n1 | grep -q '^appended$' || { echo "append did not go to the end" >&2; exit 1; }

echo "replace_block: inserts once, replaces in place, leaves the rest alone"
