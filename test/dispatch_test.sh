#!/usr/bin/env bash
# Every command bin/nook dispatches must land on a cmd_ function that exists in
# the library that arm sources. A typo here is invisible until someone runs the
# command, and `set -u` turns it into an unbound-variable error rather than
# anything readable.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Aliases the dispatcher rewrites before calling: pattern => function suffix.
declare -A ALIAS=([unmount]=umount [detach]=eject)
# Handled inline in the dispatcher, with no cmd_ function behind them.
INLINE=" ssh help -h --help version -v --version * "

declared=$(grep -ho '^cmd_[a-z_]*()' lib/*.sh | sed 's/()//' | sort -u)

commands=$(
  sed -n '/^case \$cmd in$/,/^esac$/p' bin/nook |
    grep -E '^  [a-z*|_ -]+\)$' |
    sed 's/)$//; s/|/ /g'
)

# The catch-all arm is a literal `*` in the case statement; without noglob the
# word split below expands it against the working directory.
set -f
bad=0
for c in $commands; do
  [[ $INLINE == *" $c "* ]] && continue
  name=${ALIAS[$c]:-$c}
  grep -qx "cmd_$name" <<<"$declared" || {
    echo "bin/nook dispatches '$c' but no cmd_$name is defined in lib/" >&2
    bad=1
  }
done

# And the other way: a cmd_ function nobody can reach is dead code.
for f in $declared; do
  name=${f#cmd_}
  grep -qE "^  [a-z*|_ -]*\b$name\b[a-z*|_ -]*\)$" <<<"$(sed -n '/^case \$cmd in$/,/^esac$/p' bin/nook)" || {
    echo "lib/ defines $f but bin/nook never dispatches to it" >&2
    bad=1
  }
done

[[ $bad == 0 ]] && echo "dispatch: every command reaches a defined function"
exit $bad
