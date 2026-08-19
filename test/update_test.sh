#!/usr/bin/env bash
# `nook update` runs unattended from a timer, which makes two things matter more
# than they would by hand: it must never rewrite a checkout somebody is working
# in, and it must say nothing at all on the days there is nothing to say.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO=$PWD
bad=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HOME=$work/home
export NOOK_HOME=$HOME/.nook
mkdir -p "$HOME/.config/systemd/user" "$NOOK_HOME"
LOG=$work/log
: >"$LOG"

# A checkout, as far as the command can tell: git and systemctl are stubs that
# record what they were asked and answer from files this test writes.
root=$work/root
mkdir -p "$root/.git" "$root/systemd"
cp "$REPO/systemd/nook-update.service" "$REPO/systemd/nook-update.timer" "$root/systemd/"
printf '#!/usr/bin/env bash\necho "INSTALL" >>"%s"\n' "$LOG" >"$root/install.sh"
chmod +x "$root/install.sh"

mkdir -p "$work/bin"
cat >"$work/bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >>"$LOG"
case "\$*" in
  *"rev-parse --short HEAD") cat "$work/head" ;;
  *"pull --quiet --ff-only")
    [[ -f $work/refuse ]] && exit 1
    cat "$work/after" >"$work/head" 2>/dev/null
    ;;
  *"rev-list --count"*) echo 3 ;;
  *"log --oneline"*) echo "abc1234 something" ;;
  *"status --porcelain") : ;;
esac
exit 0
STUB
cat >"$work/bin/systemctl" <<STUB
#!/usr/bin/env bash
echo "systemctl \$*" >>"$LOG"
case "\$*" in
  *"is-enabled nook-update.timer") [[ -f $work/timer-on ]] || exit 1 ;;
esac
exit 0
STUB
chmod +x "$work/bin"/*
PATH=$work/bin:$PATH

# shellcheck source=lib/common.sh
source lib/common.sh
# shellcheck source=lib/init.sh
source lib/init.sh

says() { # <label> <expected substring> <actual>
  [[ $3 == *"$2"* ]] && return 0
  echo "update: $1" >&2
  echo "  expected: $2" >&2
  echo "  got:      $(tr '\n' '|' <<<"$3")" >&2
  bad=1
}

# ── scheduling it ────────────────────────────────────────────────────────────
out=$(cmd_update "$root" --auto)
says "--auto does not say what it did" "daily" "$out"
[[ -f $HOME/.config/systemd/user/nook-update.timer ]] ||
  { echo "update: --auto installed no timer" >&2; bad=1; }
[[ -f $HOME/.config/systemd/user/nook-update.service ]] ||
  { echo "update: --auto installed a timer with no service to run" >&2; bad=1; }
says "--auto does not enable the timer" "enable --now nook-update.timer" "$(cat "$LOG")"

: >"$LOG"
out=$(cmd_update "$root" --no-auto)
says "--no-auto does not disable the timer" "disable --now nook-update.timer" "$(cat "$LOG")"
says "--no-auto does not say updates are manual again" "by hand" "$out"

touch "$work/timer-on"
says "the timer state is not reported" "daily" "$(update_timer_state)"
rm -f "$work/timer-on"
says "a machine without the timer is not reported as manual" "by hand" "$(update_timer_state)"

# ── the quiet path the timer takes ───────────────────────────────────────────
echo aaaaaaa >"$work/head"
echo aaaaaaa >"$work/after"
: >"$LOG"
out=$(cmd_update "$root" --quiet)
[[ -z $out ]] || { echo "update: --quiet said something on a day nothing changed: $out" >&2; bad=1; }
if grep -q INSTALL "$LOG"; then
  echo "update: --quiet re-ran install.sh without an update to install" >&2
  bad=1
fi

echo aaaaaaa >"$work/head"
echo bbbbbbb >"$work/after"
: >"$LOG"
out=$(cmd_update "$root" --quiet)
says "a real update is not announced" "nook updated to bbbbbbb" "$out"
if ! grep -q INSTALL "$LOG"; then
  echo "update: an update did not re-link anything — install.sh never ran" >&2
  bad=1
fi

# ── the checkout somebody is working in ──────────────────────────────────────
touch "$work/refuse"
echo aaaaaaa >"$work/head"
: >"$LOG"
out=$(cmd_update "$root" --quiet)
[[ -z $out ]] || { echo "update: a refused pull nags from the timer: $out" >&2; bad=1; }
if grep -q INSTALL "$LOG"; then
  echo "update: a refused pull still re-ran install.sh" >&2
  bad=1
fi
if out=$(cmd_update "$root" 2>&1); then
  echo "update: a refused pull by hand reported success" >&2
  bad=1
else
  says "a refused pull does not say why" "modified" "$out"
fi
rm -f "$work/refuse"

# The one flag that must never be guessed at: --auto and --no-auto differ by
# three characters, and a typo that silently updated would be a bad surprise.
# A subshell, because `die` exits the shell it runs in — which here is the test.
if (cmd_update "$root" --daily) >/dev/null 2>&1; then
  echo "update: an unknown flag was accepted" >&2
  bad=1
fi

# ── what doctor says about it ────────────────────────────────────────────────
# shellcheck disable=SC2034  # cli_state in lib/status.sh reads it
ROOT=$root
# shellcheck source=lib/drive.sh
source lib/drive.sh
# shellcheck source=lib/status.sh
source lib/status.sh
says "doctor does not point at the fix when this machine is behind" \
  "nook update" "$(cli_state)"

((bad)) || echo "update: schedules itself, stays quiet, and never rewrites a checkout in use"
exit "$bad"
