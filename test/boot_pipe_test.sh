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

# systemctl has to answer too, or the "is a run already going" check decides it
# is. Inactive by default, so the normal path is the one under test.
cat >"$stub/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ $* == *is-active* ]] && exit 3
[[ $* == *"show -p Result"* ]] && { echo success; exit 0; }
exit 0
STUB
chmod +x "$stub/systemctl"

cat >"$stub/journalctl" <<'STUB'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*"
STUB
chmod +x "$stub/journalctl"

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
# Telling someone to go and run journalctl is asking them to do what the script
# can do itself.
grep -q 'journalctl .*-fu nook-boot' <<<"$out" || {
  echo "the detached run did not follow its own log: $out" >&2
  exit 1
}

# And the escape hatch has to actually stay put.
out=$(PATH="$stub:$PATH" unshare -r bash pi/boot.sh --no-detach --name testbox 2>&1 || true)
grep -q 'systemd-run' <<<"$out" && {
  echo "--no-detach detached anyway: $out" >&2
  exit 1
}

# And when one is already running, join it rather than failing to claim the name.
# is-active answers yes once — enough to take the "already going" branch — then
# no, so the follow loop terminates instead of spinning forever.
cat >"$stub/systemctl" <<STUB
#!/usr/bin/env bash
state=$stub/seen-active
if [[ \$* == *is-active* ]]; then
  [[ -f \$state ]] && exit 3
  : >"\$state"
  exit 0
fi
[[ \$* == *"show -p Result"* ]] && { echo success; exit 0; }
exit 0
STUB
chmod +x "$stub/systemctl"

out=$(PATH="$stub:$PATH" unshare -r bash pi/boot.sh --detach 2>&1)
grep -q 'journalctl .*-fu nook-boot' <<<"$out" || {
  echo "a second run did not follow the one already going: $out" >&2
  exit 1
}
grep -q 'systemd-run' <<<"$out" && {
  echo "a second run started another unit on top of the first: $out" >&2
  exit 1
}

echo "boot: survives curl|bash, keeps its flags, prefers a checkout, detaches, follows its own log"
