#!/usr/bin/env bash
# More than one nook on one machine. Two boxes must not share a mount point, a
# drive label, a docker context or an nbd device — every one of those collisions
# looks like the wrong machine answering.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NOOK_HOME=$(mktemp -d)
export NOOK_HOME
trap 'rm -rf "$NOOK_HOME"' EXIT

# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/init.sh
source lib/init.sh

make_nook() {
  mkdir -p "$NOOK_HOME/$1"
  cat >"$NOOK_HOME/$1/config" <<EOF
NOOK_HOST=$1
NOOK_SSH_USER=${3:-}
NOOK_NAME=$1
NOOK_DATA=/mnt/nook
NOOK_TRANSPORT=$2
NOOK_TARGET_IQN=iqn.2026-08.dev.nook:$1
EOF
}

make_nook pi nbd admin
make_nook thinkcentre iscsi
printf 'pi\n' >"$NOOK_HOME/default"

[[ $(nooks | paste -sd,) == "pi,thinkcentre" ]] || { echo "nooks did not list both" >&2; exit 1; }
[[ $(current_nook) == pi ]] || { echo "default is not pi" >&2; exit 1; }

load_config
pi_mount=$NOOK_MOUNT
pi_label=$NOOK_LABEL
pi_context=$NOOK_CONTEXT

# Deliberately in-process rather than in a subshell: load_config has to be
# callable twice, because `nook status --all` calls it once per nook.
NOOK=thinkcentre load_config
[[ $NOOK_MOUNT != "$pi_mount" ]] || { echo "both nooks mount at $NOOK_MOUNT" >&2; exit 1; }
[[ $NOOK_LABEL != "$pi_label" ]] || { echo "both drives carry the label $NOOK_LABEL" >&2; exit 1; }
[[ $NOOK_CONTEXT != "$pi_context" ]] || { echo "both use the docker context $NOOK_CONTEXT" >&2; exit 1; }
# A label longer than ext4 allows is a mkfs failure at the worst moment.
[[ ${#NOOK_LABEL} -le 16 ]] || { echo "label $NOOK_LABEL is over 16 characters" >&2; exit 1; }

# The env override wins over the default without changing it.
[[ $(NOOK=thinkcentre current_nook) == thinkcentre ]] || { echo "NOOK= did not override" >&2; exit 1; }
[[ $(current_nook) == pi ]] || { echo "NOOK= leaked into the default" >&2; exit 1; }

cmd_use thinkcentre >/dev/null
# load_config leaves NOOK set to whatever it loaded, and an explicit NOOK is
# meant to beat the default — so clear it before asking what the default is.
unset NOOK
[[ $(current_nook) == thinkcentre ]] || { echo "use did not change the default" >&2; exit 1; }
[[ $(NOOK=pi current_nook) == pi ]] || { echo "NOOK= no longer beats the default" >&2; exit 1; }

# One block for every nook, rewritten as a set — never one block per box.
HOME=$NOOK_HOME write_ssh_config
config="$NOOK_HOME/.ssh/config"
[[ $(grep -c '^Host ' "$config") == 2 ]] || { echo "ssh config does not carry both hosts" >&2; exit 1; }
[[ $(grep -c '^# >>> nook$' "$config") == 1 ]] || { echo "more than one nook block" >&2; exit 1; }
# The account on the box is rarely the local one, and ssh has to be told.
grep -q '^	User admin$' "$config" || { echo "the box's ssh user did not reach the config" >&2; exit 1; }
[[ $(grep -c '^	User ' "$config") == 1 ]] || { echo "a User line appeared for a nook that has none" >&2; exit 1; }

# Forgetting drops the entry and moves the default somewhere that still exists.
systemctl() { :; }
docker() { :; }
HOME=$NOOK_HOME cmd_forget thinkcentre >/dev/null
[[ $(nooks | paste -sd,) == "pi" ]] || { echo "forget left the directory behind" >&2; exit 1; }
[[ $(current_nook) == pi ]] || { echo "forget left the default pointing at nothing" >&2; exit 1; }
[[ $(grep -c '^Host ' "$config") == 1 ]] || { echo "forget left a Host block behind" >&2; exit 1; }

# The single-nook layout that shipped first still works without re-adopting.
rm -rf "${NOOK_HOME:?}"/*
cat >"$NOOK_HOME/config" <<'EOF'
NOOK_HOST=oldbox
NOOK_NAME=oldbox
NOOK_TRANSPORT=nbd
EOF
migrate_single_nook 2>/dev/null
[[ -f $NOOK_HOME/oldbox/config ]] || { echo "the old single-file config was not migrated" >&2; exit 1; }
[[ $(current_nook) == oldbox ]] || { echo "migration did not set a default" >&2; exit 1; }

echo "nooks: two boxes stay apart, use/forget behave, the old layout migrates"
