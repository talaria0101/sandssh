#!/bin/sh
# tests/bootstrap.sh - the end to end: install a toolchain into a home root that
# does NOT run binaries, prove the exec split put it where it runs, and prove the
# written environment reproduces that in a shell that never ran the bootstrap.
#
# ⛔ THE HOME ROOT IS CHOSEN FOR ITS PROPERTY, NOT ITS NAME. When this host has a
# writable mount that denies exec, the test uses it so the split is exercised for
# real; when it has none, the install half still runs and the clauses that need a
# split are reported as such. Choosing /tmp and asserting a split would have
# passed for the wrong reason on this very sandbox once already.
#
# Exit 2 when there is no network or no curl/wget, because the toolchain is
# fetched and that is `could not run`, not `failed`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"
for m in common detect space; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo 'bootstrap: no curl or wget to fetch with' >&2
    exit 2
fi
if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null 'https://github.com/jqlang/jq/releases/latest' 2>/dev/null || {
        echo 'bootstrap: no network to github.com' >&2
        exit 2
    }
fi

t_begin bootstrap

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Pick a home root that cannot exec, so the split is real. /state/home and
# /workspace are the noexec mounts in the sandbox this was built for; /tmp is the
# fallback and collapses the two roots.
noexec_base=''
exec_base=''
for cand in /state/home /workspace /tmp; do
    [ -d "$cand" ] && [ -w "$cand" ] || continue
    if sh_exec_probe "$cand"; then
        [ -z "$exec_base" ] && exec_base=$cand
    else
        [ -z "$noexec_base" ] && noexec_base=$cand
    fi
done
if [ -n "$noexec_base" ]; then
    home="$noexec_base/.sandhome-e2e.$$"
else
    home="$work/home"
fi
exec_root="$work/exec"

out=$(SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
      sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line 2>"$work/err.txt")
status=$?
if [ "$status" != 0 ]; then
    case "$(cat "$work/err.txt")" in
        *'could not download'*|*'could not fetch'*|*'does not match'*)
            echo 'bootstrap: the fetch failed; treating this as could-not-run' >&2
            exit 2 ;;
    esac
fi
t_is "$status" 0 'bootstrap exits 0 on the minimal toolset'
t_contains "$out" 'failures=0' 'the report says no failures'
t_contains "$out" 'installed=jq' 'the first run installs jq'
t_ok "$([ -r "$home/env.sh" ]; echo $?)" 'env.sh was written'
t_ok "$([ -f "$home/toolchains/jq/bin/jq" ]; echo $?)" 'the downloaded jq sits in the home root'

if [ -n "$noexec_base" ]; then
    t_contains "$out" 'home_exec=no' 'a noexec home was detected as noexec'
    if sh_exec_probe "$home"; then
        t_ok 1 'the home root really refuses exec'
    else
        t_ok 0 'the home root really refuses exec'
    fi
    t_ok "$([ -x "$exec_root/bin/jq" ] || [ -L "$exec_root/bin/jq" ]; echo $?)" 'the promoted jq is on the exec root'
fi

# A fresh shell that reads only env.sh must find and run jq.
probe=$(env -i HOME="$work/fakehome" PATH=/usr/bin:/bin \
        SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
        sh -c '. "$SANDHOME_HOME/env.sh"; command -v jq >/dev/null 2>&1 && jq --version' 2>/dev/null)
case "$probe" in
    jq-*) t_ok 0 "a fresh shell runs jq through env.sh ($probe)" ;;
    *)    t_ok 1 "a fresh shell runs jq through env.sh (got '$probe')" ;;
esac

# The second run must ADOPT what the first installed, not download it again.
out2=$(SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
       sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line 2>/dev/null)
t_contains "$out2" 'adopted=jq' 'the second run adopts the first run install'
case "$out2" in
    *'installed=jq'*) t_ok 1 'the second run does not reinstall jq' ;;
    *)                t_ok 0 'the second run does not reinstall jq' ;;
esac

# A dry run installs nothing and must not claim a built shim: the report is read
# from the machine, and one line saying otherwise is the claim this tree refuses.
dryhome="$work/dry-home"
dryout=$(SANDHOME_HOME="$dryhome" SANDHOME_EXEC="$work/dry-exec" \
         sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --dry-run 2>/dev/null)
t_contains "$dryout" 'shims=' 'a dry run reports no built shims'
case "$dryout" in
    *'shims=fakepty'*|*'shims=fakepwd'*) t_ok 1 'a dry run names no built shim' ;;
    *)                                  t_ok 0 'a dry run names no built shim' ;;
esac
t_ok "$([ ! -e "$dryhome/shims/fakepty.so" ]; echo $?)" 'a dry run writes no shim object'
t_ok "$([ ! -d "$dryhome/toolchains/jq" ]; echo $?)" 'a dry run downloads no toolchain'
SANDHOME_REPO="$ROOT" SANDHOME_HOME="$dryhome" SANDHOME_EXEC="$work/dry-exec" \
    sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
if [ $? -eq 0 ]; then
    t_ok 1 'doctor exits non-zero on a home that is not set up'
else
    t_ok 0 'doctor exits non-zero on a home that is not set up'
fi

rm -rf "$home" 2>/dev/null
t_end
