#!/usr/bin/env bash
# nook-upgrade runs at four in the morning with nobody watching, so the failures
# that matter are the quiet ones: filling the disk, restarting a service into a
# crash loop and leaving it there, or pruning the image that would have been the
# way back.
#
# No box and no docker: docker is a stub that answers from files this test
# writes, and records what it was asked.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
UPGRADE=$PWD/pi/bin/nook-upgrade
bad=0

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

data=$root/data
mkdir -p "$data/stacks/jellyfin" "$root/bin" "$root/state"
printf 'services:\n  jellyfin:\n    image: jellyfin/jellyfin\n' >"$data/stacks/jellyfin/compose.yaml"
cat >"$root/nook.conf" <<CONF
NOOK_NAME=testbox
NOOK_DATA=$data
CONF

# The stub reads three files: what `images` should say before and after a pull,
# and whether the container comes up healthy.
cat >"$root/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$root/docker.log"
case "\$*" in
  "info --format {{.DockerRootDir}}") echo "$data" ;;
  *"images --format json")
    if [[ -f $root/pulled ]]; then cat "$root/after.json"; else cat "$root/before.json"; fi ;;
  *"pull --quiet"*)
    [[ -f $root/registry-down ]] && exit 1
    touch "$root/pulled" ;;
  *"ps -q"*) echo deadbeef ;;
  "inspect -f {{.State.Status}} deadbeef")
    if [[ -f $root/rolled-back || ! -f $root/unhealthy ]]; then echo running; else echo restarting; fi ;;
  "inspect -f {{if .State.Health}}{{.State.Health.Status}}{{end}} deadbeef") echo healthy ;;
  "tag "*) touch "$root/rolled-back" ;;
esac
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/sleep"
chmod +x "$root/bin"/*

printf '[{"Repository":"jellyfin/jellyfin","Tag":"latest","ID":"old111"}]\n' >"$root/before.json"
printf '[{"Repository":"jellyfin/jellyfin","Tag":"latest","ID":"new222"}]\n' >"$root/after.json"

run() {
  rm -f "$root/pulled" "$root/rolled-back"
  : >"$root/docker.log"
  PATH="$root/bin:$PATH" NOOK_CONF=$root/nook.conf NOOK_STATE=$root/state \
    NOOK_UPGRADE_SETTLE=6 NOOK_UPGRADE_MIN_FREE=${MIN_FREE:-0} \
    bash "$UPGRADE" "$@" 2>&1
}

says() { # <label> <expected substring> <actual>
  [[ $3 == *"$2"* ]] && return 0
  echo "upgrade: $1" >&2
  echo "  expected: $2" >&2
  echo "  got:      $(tr '\n' '|' <<<"$3")" >&2
  bad=1
}

state() { cat "$root/state/last-upgrade.json" 2>/dev/null; }

# ── nothing changed ──────────────────────────────────────────────────────────
cp "$root/before.json" "$root/after.json"
out=$(run)
says "an unchanged stack is not reported as current" "up to date" "$out"
if grep -q "up -d" "$root/docker.log"; then
  echo "upgrade: a service that did not change was restarted anyway" >&2
  bad=1
fi
printf '[{"Repository":"jellyfin/jellyfin","Tag":"latest","ID":"new222"}]\n' >"$root/after.json"

# ── a good upgrade ───────────────────────────────────────────────────────────
rm -f "$root/unhealthy"
out=$(run)
says "a real upgrade is not reported" "upgraded: jellyfin" "$out"
says "the compose project was never brought up" "up -d" "$(cat "$root/docker.log")"
says "nothing was pruned after a good upgrade" "image prune" "$(cat "$root/docker.log")"
says "the run was not recorded" '"changed":["jellyfin"]' "$(state)"

# ── an upgrade that does not come up ─────────────────────────────────────────
touch "$root/unhealthy"
out=$(run) || true
says "a crash-looping service was not rolled back" "putting the old image back" "$out"
says "the old image was never re-tagged" "tag old111 jellyfin/jellyfin:latest" "$(cat "$root/docker.log")"
says "the rollback did not recreate the containers" "up -d --force-recreate" "$(cat "$root/docker.log")"
if grep -q "image prune" "$root/docker.log"; then
  echo "upgrade: it pruned after a rollback — that deletes the image it just put back" >&2
  bad=1
fi
says "a rollback was not recorded" '"rolled_back":["jellyfin"]' "$(state)"
rm -f "$root/unhealthy"

# ── no room to pull into ─────────────────────────────────────────────────────
out=$(MIN_FREE=999999 run)
says "a full disk did not stop the pull" "not pulling anything" "$out"
if grep -q "pull" "$root/docker.log"; then
  echo "upgrade: it pulled anyway on a box with no room" >&2
  bad=1
fi
says "the skip was not recorded" '"reason":"low disk"' "$(state)"

# ── the registry is unreachable ──────────────────────────────────────────────
touch "$root/registry-down"
out=$(run)
says "an unreachable registry is not reported" "could not reach the registry" "$out"
says "an unreachable registry was not recorded" '"unreachable":["jellyfin"]' "$(state)"
rm -f "$root/registry-down"

# ── quiet, for the timer ─────────────────────────────────────────────────────
cp "$root/before.json" "$root/after.json"
out=$(run --quiet)
[[ -z $out ]] || { echo "upgrade: --quiet talked on a night nothing changed: $out" >&2; bad=1; }

((bad)) || echo "upgrade: checks for room, waits for health, rolls back, and prunes only when it worked"
exit "$bad"
