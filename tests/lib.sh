#!/bin/sh
# tests/lib.sh - the tiny harness every sandhome test sources. POSIX sh.
# Sourced, never executed. Each test file counts and prints its own result.

: "${TESTS_NAME:=test}"
TESTS_RUN=0
TESTS_FAIL=0

t_begin() {
    TESTS_NAME=$1
    TESTS_RUN=0
    TESTS_FAIL=0
    printf '== %s\n' "$TESTS_NAME"
}

t_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" -eq 0 ]; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n' "$2"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

t_is() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (got %s, wanted %s)\n' "$3" "$1" "$2"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

t_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *)      printf '  FAIL %s (no %s in %s)\n' "$3" "$2" "$1"
                TESTS_FAIL=$((TESTS_FAIL + 1)) ;;
    esac
}

t_end() {
    printf '%s: %s run, %s failed\n' "$TESTS_NAME" "$TESTS_RUN" "$TESTS_FAIL"
    [ "$TESTS_FAIL" -eq 0 ] || return 1
    return 0
}

# tests_repo_dir -> the checkout root, from this file's location.
tests_repo_dir() {
    CDPATH='' cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd
}
