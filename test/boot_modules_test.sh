#!/usr/bin/env bash
# pi/boot.sh sources its modules rather than executing them, so a module that
# calls `exit` takes the whole run down halfway through. And a module on disk
# that is not in MODULES never runs at all, silently.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bad=0

listed=$(sed -n 's/^MODULES=(\(.*\))$/\1/p' pi/boot.sh | tr ' ' '\n' | sort)
[[ -n $listed ]] || { echo "no MODULES array found in pi/boot.sh" >&2; exit 1; }
on_disk=$(find pi/modules -name '*.sh' -exec basename {} .sh \; | sort)

diff <(echo "$listed") <(echo "$on_disk") >/dev/null || {
  echo "pi/boot.sh MODULES and pi/modules/ disagree:" >&2
  diff <(echo "$listed") <(echo "$on_disk") >&2 || true
  bad=1
}

for f in pi/modules/*.sh; do
  # `exit 0` inside a subshell or a heredoc is fine; a bare top-level one is not.
  grep -nE '^\s*exit\b' "$f" && {
    echo "$f calls exit at the top level — modules are sourced, use return" >&2
    bad=1
  }
done

# Modules run under `set -e` from boot.sh, where a bare `cond && action` guard
# that turns out false ends the run.
for f in pi/modules/*.sh pi/boot.sh; do
  grep -nE '^\s*\[\[[^]]*\]\] && \{' "$f" && {
    echo "$f uses a '[[ ]] && { }' guard — under set -e write it as an if" >&2
    bad=1
  }
done

[[ $bad == 0 ]] && echo "boot: every module is listed, sourced-safe, and set -e clean"
exit $bad
