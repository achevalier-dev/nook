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

# A session that its own package installs can kill must not be the thing the
# run depends on staying alive.
cat >"$stub/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s
' "$*"
STUB
chmod +x "$stub/systemd-run"

# The detach only happens once the script is root, so the check has to be root
# too. A user namespace gives EUID 0 without any privilege at all.
if ! unshare -r true 2>/dev/null; then
  echo "boot: survives curl|bash, keeps its flags, prefers a checkout (detach: skipped, no user namespaces)"
  exit 0
fi

out=$(PATH="$stub:$PATH" unshare -r bash pi/boot.sh --detach --name testbox 2>&1)
grep -q 'systemd-run .*--unit=nook-boot' <<<"$out" || {
  echo "--detach did not move the run into a transient unit: $out" >&2
  exit 1
}
grep -q 'NOOK_DETACHED=1' <<<"$out" || {
  echo "the detached run was not marked, so it would detach again forever: $out" >&2
  exit 1
}
grep -q -- '--name testbox' <<<"$out" || {
  echo "--detach lost the other flags: $out" >&2
  exit 1
}

# And the escape hatch has to actually stay put.
out=$(PATH="$stub:$PATH" unshare -r bash pi/boot.sh --no-detach --name testbox 2>&1 || true)
grep -q 'systemd-run' <<<"$out" && {
  echo "--no-detach detached anyway: $out" >&2
  exit 1
}

echo "boot: survives curl|bash, keeps its flags, prefers a checkout, detaches on request"
