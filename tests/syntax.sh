#!/bin/sh
# tests/syntax.sh - every shell file in this tree parses under the POSIX shells
# that will read it. `dash -n` is the check that matters; bash --posix is a
# second reader, so a file that is valid under dash and not under bash is found
# here rather than on the machine it was installed on.
#
# Exit 2 when there is no dash at all: `could not run` is not `passed`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

if ! command -v dash >/dev/null 2>&1; then
    echo 'syntax: no dash to check with' >&2
    exit 2
fi
HAS_BASH=no
command -v bash >/dev/null 2>&1 && HAS_BASH=yes

t_begin syntax
for f in "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome "$ROOT"/lib/*.sh \
         "$ROOT"/tools/*.sh "$ROOT"/tests/*.sh "$ROOT"/shell/errandsh; do
    [ -f "$f" ] || continue
    rel=${f#"$ROOT"/}
    if dash -n "$f" 2>/tmp/sandhome-syntax.err; then
        t_ok 0 "dash -n $rel"
    else
        t_ok 1 "dash -n $rel: $(cat /tmp/sandhome-syntax.err)"
    fi
    if [ "$HAS_BASH" = yes ]; then
        if bash --posix -n "$f" 2>/tmp/sandhome-syntax.err; then
            t_ok 0 "bash --posix -n $rel"
        else
            t_ok 1 "bash --posix -n $rel: $(cat /tmp/sandhome-syntax.err)"
        fi
    fi
done
rm -f /tmp/sandhome-syntax.err
t_end
