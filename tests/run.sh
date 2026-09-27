#!/bin/sh
# tests/run.sh - run every sandhome test. Exit 0 all green, 1 a test failed,
# 2 at least one test could not run here. `could not run` is a different claim
# from `failed` and is reported separately.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAILED=''
SKIPPED=''
PASSED=''

for t in syntax unit space toolchain shims bootstrap errandsh-posix; do
    script="$HERE/$t.sh"
    [ -r "$script" ] || continue
    printf '\n#### %s\n' "$t"
    # ⛔ ALWAYS THROUGH AN INTERPRETER, NEVER BY EXECING THE FILE. This tree is
    # worked on from a checkout that may itself be on a noexec mount, and
    # `./tests/x.sh` then fails with `Permission denied` on a file that is fine.
    # A test is a script; naming its reader is the portable way to run it.
    first=''
    IFS= read -r first < "$script" 2>/dev/null || first=''
    case "$first" in
        *bash*) bash "$script" ;;
        *)      sh "$script" ;;
    esac
    case "$?" in
        0) PASSED="$PASSED $t" ;;
        2) SKIPPED="$SKIPPED $t" ;;
        *) FAILED="$FAILED $t" ;;
    esac
done

printf '\n===============================\n'
printf 'passed :%s\n' "$PASSED"
printf 'skipped:%s\n' "$SKIPPED"
printf 'failed :%s\n' "$FAILED"
if [ -n "$FAILED" ]; then
    exit 1
fi
if [ -n "$SKIPPED" ]; then
    exit 2
fi
exit 0
