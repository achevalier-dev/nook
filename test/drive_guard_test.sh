#!/usr/bin/env bash
# The fixture here stands in for load_config; every variable it sets is read by
# lib/drive.sh rather than by this file.
# shellcheck disable=SC2034
# The one invariant that costs real data if it breaks: `nook attach` must refuse
# while another machine holds the drive. Runs against a stubbed nook — no SSH,
# no sudo, no block device.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NOOK_HOME=$(mktemp -d)
export NOOK_HOME
trap 'rm -rf "$NOOK_HOME"' EXIT

# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/drive.sh
source lib/drive.sh

# What load_config would have set, stood up by hand so the real cmd_ functions
# run unchanged. They look unused here because their readers live in lib/.
NOOK=stub
NOOK_DIR="$NOOK_HOME/stub"
mkdir -p "$NOOK_DIR"
NOOK_HOST=stub
NOOK_TRANSPORT=nbd
NOOK_LABEL=STUB
NBD_DEV=/dev/null/never
load_config() { :; }
notify() { echo "$1"; }

# What nook-target prints when somebody else is attached.
remote() {
  cat <<'EOF'
transport   nbd
image       /mnt/nook/disk.img
export      nook
portal      100.64.0.1:10809
attached    100.64.0.9
EOF
}

if out=$(cmd_attach 2>&1); then
  echo "attach succeeded while the drive was held: $out" >&2
  exit 1
fi
grep -q "another machine has the drive attached" <<<"$out" || {
  echo "attach failed, but not on the holder check: $out" >&2
  exit 1
}
grep -q "100.64.0.9" <<<"$out" || {
  echo "the refusal does not name who is holding it: $out" >&2
  exit 1
}

# And it must go ahead when nobody is.
remote() { echo "attached    none"; }
sudo() { echo "sudo $*"; }
nbd-client() { :; }
allocate_nbd() { echo /dev/nbd0; }
wait_for_disk() { echo /dev/null; }
mounted_at() { echo /run/media/test/NOOK; }
if ! out=$(cmd_attach 2>&1); then
  echo "attach refused an unheld drive: $out" >&2
  exit 1
fi

echo "drive: attach refuses a held drive and names the holder"
