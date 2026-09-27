#!/bin/sh
# tests/shims.sh - build and actually use both LD_PRELOAD shims.
#
# A shim that compiles and is never called is a claim, not a capability. The two
# probes below exercise isatty(0) over a pipe and getpwnam over a synthetic
# database, in the exact shape a cage has: no pty, no /etc/passwd.
#
# Exit 2 when there is no C compiler, because that is `could not run`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env shim; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR
SH_SELF=shims-test

if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo 'shims: no C compiler to build with' >&2
    exit 2
fi

t_begin shims
sh_detect_all

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-shims.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

SH_HOME="$tmp"; SH_HOME_TMP="$tmp/tmp"; export SH_HOME SH_HOME_TMP
mkdir -p "$SH_HOME_TMP"

sh_shim_build fakepty "$ROOT/shims/fakepty.c" && t_ok 0 'fakepty compiles' || t_ok 1 'fakepty compiles'
sh_shim_build fakepwd "$ROOT/shims/fakepwd.c" && t_ok 0 'fakepwd compiles' || t_ok 1 'fakepwd compiles'
t_ok "$([ -f "$(sh_shims_dir)/fakepty.so" ] && [ -f "$(sh_shims_dir)/fakepwd.so" ]; echo $?)" 'both shared objects exist'

cat > "$tmp/probe.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <pwd.h>
int main(void){
    struct passwd *p = getpwnam("sandhome-test");
    printf("isatty0=%d name=%s\n", isatty(0), p ? p->pw_name : "(none)");
    return 0;
}
EOF
cc -O2 -o "$tmp/probe" "$tmp/probe.c" 2>/dev/null || gcc -O2 -o "$tmp/probe" "$tmp/probe.c" 2>/dev/null
t_ok "$([ -x "$tmp/probe" ]; echo $?)" 'the probe compiles'

# Without any shim: stdin is /dev/null, so no isatty, and the synthetic user is
# not in the real database.
out=$( "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=0' 'without fakepty a pipe is not a terminal'
t_contains "$out" 'name=(none)' 'without fakepwd the user is absent'

# fakepty alone.
out=$( LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=1' 'fakepty makes fds 0-2 look like a terminal'

# fakepwd alone, with the synthetic database it is pointed at.
{
    printf 'sandhome-test:x:4242:4242:test:/tmp:/bin/sh\n'
} > "$(sh_shims_dir)/passwd"
out=$( SANDSSH_PASSWD="$(sh_shims_dir)/passwd" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'name=sandhome-test' 'fakepwd answers getpwnam from SANDSSH_PASSWD'

t_end
