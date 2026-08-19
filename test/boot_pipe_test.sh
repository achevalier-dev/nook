#!/usr/bin/env bash
# `curl … | bash` is the documented way to run pi/boot.sh, and it is the one way
# $0 does not name the script: bash read it from stdin, so $0 and BASH_SOURCE
# both point at the bash binary. Handing that to `sudo bash` runs the
# interpreter as its own input and dies with "cannot execute binary file".
#
# Runs against a stub sudo, so nothing here needs root or a Raspberry Pi.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT

# Prints what it was asked to run and stops there, instead of running it.
cat >"$stub/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*"
STUB
chmod +x "$stub/sudo"

# Piped, the way the README says to run it.
out=$(PATH="$stub:$PATH" bash -s -- --name testbox <pi/boot.sh 2>&1)

grep -q 'curl ' <<<"$out" || {
  echo "piped boot.sh did not re-fetch itself under sudo; it ran:" >&2
  echo "  $out" >&2
  exit 1
}
grep -qE 'bash (/usr)?/bin/(bash|sh)' <<<"$out" && {
  echo "piped boot.sh tried to exec the shell binary as a script:" >&2
  echo "  $out" >&2
  exit 1
}
grep -q -- '--name testbox' <<<"$out" || {
  echo "the flags were lost across the sudo re-exec: $out" >&2
  exit 1
}

# From a checkout there *is* a file, and re-fetching it would be silly.
out=$(PATH="$stub:$PATH" bash pi/boot.sh --name testbox 2>&1)
grep -q 'pi/boot.sh' <<<"$out" || {
  echo "boot.sh on disk did not re-exec itself: $out" >&2
  exit 1
}
grep -q 'curl ' <<<"$out" && {
  echo "boot.sh on disk re-fetched itself instead of using the checkout: $out" >&2
  exit 1
}

echo "boot: survives curl|bash, keeps its flags, and prefers a checkout"
