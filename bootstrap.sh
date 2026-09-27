#!/bin/sh
# bootstrap.sh - bring a sandbox up to a named set of toolchains, with the
# environment and the two filesystem roots handled, from one command.
#
#   sh bootstrap.sh --toolset developer
#   curl -fsSL https://raw.githubusercontent.com/talaria0101/sandssh/main/bootstrap.sh | sh -s -- --with rust
#   . ./bootstrap.sh        # with SANDHOME_NO_RUN=1, defines its functions only
#
# THE PROBLEM IT EXISTS FOR. A sandbox can mount a directory rw and still refuse
# execve(2) on it, while allowing mmap(PROT_EXEC) - so a shared library read from
# there loads and a binary in it will not run. `mount` does not have to say
# noexec; the refusal can come from a policy invisible in /proc/mounts. Every
# hand-built userland handles that differently, and the difference is found weeks
# later inside a job that fails for a reason nobody wrote down.
#
# WHAT IT DOES, IN ORDER.
#   1. detects the machine (os, kernel, arch, libc, WSL, privilege, pty, passwd);
#   2. plans two roots: a persistent SH_HOME that may be noexec, and a small
#      exec-capable SH_EXEC. When the home runs binaries the two collapse.
#   3. adopts a toolchain that is already here, and installs one that is not,
#      with its executables promoted onto the exec root and its data left on the
#      home;
#   4. builds the LD_PRELOAD shims a cage needs and a normal host does not;
#   5. writes $SH_HOME/env.sh, installs the profile fragment and the one line a
#      login file needs, and reports what it read off the machine.
#
# ⛔ IT IS POSIX sh AND IT IS CHECKED AS POSIX. No `local`, no arrays, no `[[`,
# no `$'...'`, no `a && b || c`. It depends on the shell and on almost nothing
# else: not awk, not sed, not grep, not tr, not find, not install, not dirname.
#
# EXIT CODES: 0 done, 1 something asked for could not be installed, 2 could not
# run at all.

set -u

SH_SELF=bootstrap
SH_VERSION=1
: "${SH_NO_RUN:=${SANDHOME_NO_RUN:-}}"

# ------------------------------------------------------------- locate or fetch --
# A script read from a pipe has no directory, and a modular bootstrap cannot work
# without lib/ and tools/. So when there is no directory the tree is fetched to a
# temp dir and this file re-execs itself from there. SANDHOME_NO_REFETCH stops a
# loop, and SANDHOME_REF pins the branch or tag.
SH_SELF_DIR=''
SH_FETCH_DIR=''
SH_REPO_OWNER=${SANDHOME_REPO:-talaria0101/sandssh}
SH_REPO_REF=${SANDHOME_REF:-main}

sh_bootstrap_resolve_dir() {
    case "$0" in
        */*)
            [ -f "$0" ] || return 1
            SH_SELF_DIR=$(CDPATH='' cd -- "${0%/*}" && pwd) || return 1
            ;;
        *)
            # `sh bootstrap.sh` leaves $0 as a bare filename; stdin leaves it as
            # the interpreter's name. Only the first is a file in this directory.
            [ -f "$0" ] || return 1
            SH_SELF_DIR=$(CDPATH='' cd -- . && pwd) || return 1
            ;;
    esac
    [ -r "$SH_SELF_DIR/lib/common.sh" ] || return 1
    return 0
}

sh_bootstrap_refetch() {
    printf 'bootstrap: no library beside this script; fetching %s@%s\n' \
        "$SH_REPO_OWNER" "$SH_REPO_REF" >&2
    if [ -n "${SANDHOME_NO_REFETCH:-}" ]; then
        printf 'bootstrap: [-] refetch is disabled and there is no library here\n' >&2
        exit 2
    fi
    SH_FETCH_DIR="${TMPDIR:-/tmp}/sandhome-bootstrap.$$"
    rm -rf "$SH_FETCH_DIR" 2>/dev/null
    mkdir -p "$SH_FETCH_DIR" 2>/dev/null || {
        printf 'bootstrap: [-] cannot create %s\n' "$SH_FETCH_DIR" >&2
        exit 2
    }
    sh_fr_ok=0
    for sh_fr_owner in "$SH_REPO_OWNER" talaria0101/sandhome; do
        sh_fr_url="https://codeload.github.com/$sh_fr_owner/tar.gz/refs/heads/$SH_REPO_REF"
        sh_fr_tar="$SH_FETCH_DIR/src.tar.gz"
        if sh_fr_fetch "$sh_fr_url" "$sh_fr_tar"; then
            if tar -xzf "$sh_fr_tar" -C "$SH_FETCH_DIR" 2>/dev/null; then
                sh_fr_ok=1
                break
            fi
        fi
    done
    if [ "$sh_fr_ok" != 1 ]; then
        printf 'bootstrap: [-] could not fetch %s@%s; set SANDHOME_REPO to a checkout URL or run this from a clone\n' \
            "$SH_REPO_OWNER" "$SH_REPO_REF" >&2
        exit 2
    fi
    sh_fr_dir=''
    for sh_fr_e in "$SH_FETCH_DIR"/*; do
        [ -d "$sh_fr_e" ] || continue
        if [ -r "$sh_fr_e/bootstrap.sh" ]; then
            sh_fr_dir=$sh_fr_e
            break
        fi
    done
    if [ -z "$sh_fr_dir" ]; then
        printf 'bootstrap: [-] the fetched archive has no bootstrap.sh\n' >&2
        exit 2
    fi
    printf 'bootstrap: re-executing from %s\n' "$sh_fr_dir" >&2
    SANDHOME_NO_REFETCH=1
    export SANDHOME_NO_REFETCH
    exec sh "$sh_fr_dir/bootstrap.sh" "$@"
}

# The two fetch functions are duplicated here in a minimal form on purpose: they
# are needed before any library is loadable, and a bootstrap that could not fetch
# its own library could not do anything at all.
sh_fr_fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --retry-delay 2 -o "$2" "$1"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
        return $?
    fi
    if command -v fetch >/dev/null 2>&1; then
        fetch -q -o "$2" "$1"
        return $?
    fi
    return 1
}

# ---------------------------------------------------------------- usage --
usage() {
    cat <<'USAGE'
usage: sh bootstrap.sh [options]

  --toolset NAME      minimal | cli | developer | languages | agent.
                      Default developer.
  --with LIST         comma-separated toolchain names to add
  --without LIST      comma-separated toolchain names to leave out
  --list-toolchains   print the known names and exit
  --home DIR          persistent data root. Default $XDG_DATA_HOME/sandhome
  --exec DIR          exec-capable root. Default: detected (see sandhome space)
  --no-shims          do not build the LD_PRELOAD shims
  --require-shims     refuse to finish when a needed shim could not be built
  --no-shell          do not install errandsh
  --no-profile        do not install the profile fragment or touch login files
  --no-path-line      do not add the exec bin directory to the login files
  --dry-run           print what would be done and change nothing
  --json              print the report as one JSON object
  --version           print the schema version and exit
  -h, --help          this text

  SANDHOME_REPO       owner/name to fetch when run from a pipe
  SANDHOME_REF        branch or tag to fetch. Default main
  SANDHOME_SHA256     pin a sha256 for every download this run makes
USAGE
}

# ------------------------------------------------------------------- library --
sh_load_library() {
    SH_LIB_DIR="$SH_SELF_DIR/lib"
    SH_REPO_DIR="$SH_SELF_DIR"
    export SH_LIB_DIR SH_REPO_DIR
    for sh_ll_mod in common detect space fetch env toolchain shim report; do
        if [ ! -r "$SH_LIB_DIR/$sh_ll_mod.sh" ]; then
            printf 'bootstrap: [-] missing library %s\n' "$SH_LIB_DIR/$sh_ll_mod.sh" >&2
            exit 2
        fi
        # shellcheck source=/dev/null
        . "$SH_LIB_DIR/$sh_ll_mod.sh"
    done
}

# ------------------------------------------------------------------ arguments --
SH_TOOLSET=developer
SH_WITH=''
SH_WITHOUT=''
SH_HOME_ARG=''
SH_EXEC_ARG=''
SH_SHIMS=build
SH_NEED_SHIMS=0
SH_SHELL=install
SH_PROFILE=install
SH_PATH_LINE=install
SH_JSON=0

sh_need_value() {
    if [ "$#" -lt 2 ]; then
        printf 'bootstrap: [-] %s needs a value\n' "$1" >&2
        exit 2
    fi
}

sh_toolset_names() {
    case "$1" in
        minimal)   printf 'jq\n' ;;
        cli)       printf 'jq ripgrep fd\n' ;;
        developer) printf 'jq ripgrep fd python node\n' ;;
        languages) printf 'jq ripgrep fd python node rust go\n' ;;
        agent)     printf 'jq ripgrep fd python node rust go\n' ;;
        *)         return 1 ;;
    esac
}

sh_bootstrap_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --toolset)         sh_need_value "$@"; SH_TOOLSET=$2; shift 2 ;;
            --with)            sh_need_value "$@"; SH_WITH=$2; shift 2 ;;
            --without)         sh_need_value "$@"; SH_WITHOUT=$2; shift 2 ;;
            --list-toolchains) for sh_ba_t in $(sh_toolchain_available); do
                                   printf '%s\n' "$sh_ba_t"
                               done
                               exit 0 ;;
            --home)            sh_need_value "$@"; SH_HOME_ARG=$2; shift 2 ;;
            --exec)            sh_need_value "$@"; SH_EXEC_ARG=$2; shift 2 ;;
            --no-shims)        SH_SHIMS=none; shift ;;
            --require-shims)   SH_NEED_SHIMS=1; shift ;;
            --no-shell)        SH_SHELL=none; shift ;;
            --no-profile)      SH_PROFILE=none; shift ;;
            --no-path-line)    SH_PATH_LINE=none; shift ;;
            --dry-run)         SH_DRY_RUN=1; shift ;;
            --json)            SH_JSON=1; shift ;;
            --version)         printf '%s/%s\n' "$SH_SELF" "$SH_VERSION"; exit 0 ;;
            -h|--help)         usage; exit 0 ;;
            *)                 usage >&2; printf 'bootstrap: [-] unknown argument %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    if ! sh_toolset_names "$SH_TOOLSET" >/dev/null; then
        printf 'bootstrap: [-] unknown toolset %s\n' "$SH_TOOLSET" >&2
        exit 2
    fi
}

# --------------------------------------------------------------------- steps --
sh_bootstrap_install_shell() {
    if [ "$SH_SHELL" = none ]; then
        return 0
    fi
    sh_bs_src="$SH_REPO_DIR/shell/errandsh"
    if [ ! -r "$sh_bs_src" ]; then
        sh_warn 'no shell/errandsh beside bootstrap.sh'
        return 0
    fi
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install errandsh as $SH_EXEC_BIN/errandsh"
        return 0
    fi
    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
    cp -f "$sh_bs_src" "$SH_EXEC_BIN/errandsh" || {
        sh_fail 'could not install errandsh onto the exec root'
        return 1
    }
    chmod 0755 "$SH_EXEC_BIN/errandsh" 2>/dev/null || true
    sh_step "installed $SH_EXEC_BIN/errandsh"
    return 0
}

sh_bootstrap_path_line() {
    if [ "$SH_PATH_LINE" = none ] || [ "$SH_DRY_RUN" = 1 ]; then
        return 0
    fi
    sh_bpl_line="export PATH=\"$SH_EXEC_BIN:\$PATH\""
    sh_append_login "$sh_bpl_line" "$SH_EXEC_BIN"
    sh_append_rc "$sh_bpl_line" "$SH_EXEC_BIN"
    return 0
}

sh_bootstrap_install_profile() {
    if [ "$SH_PROFILE" = none ]; then
        return 0
    fi
    sh_install_profile "$SH_REPO_DIR/lib/profile.sh"
}

# ---------------------------------------------------------------------- main --
sandhome_bootstrap_main() {
    sh_bootstrap_resolve_dir || sh_bootstrap_refetch "$@"
    sh_load_library
    sh_bootstrap_args "$@"

    if [ -n "$SH_HOME_ARG" ]; then SANDHOME_HOME=$SH_HOME_ARG; fi
    if [ -n "$SH_EXEC_ARG" ]; then SANDHOME_EXEC=$SH_EXEC_ARG; fi
    export SANDHOME_HOME SANDHOME_EXEC

    sh_detect_all
    sh_space_plan
    # ⭐ PICK UP WHAT AN EARLIER RUN INSTALLED BEFORE DECIDING WHAT TO INSTALL.
    # Without this, the second bootstrap of an already-set-up sandbox downloads
    # jq again because its probe ran against a PATH that did not yet carry the
    # exec view. Adoption is the common case on a long-lived base.
    sh_env_load

    sh_say "$SH_OS_ID on $SH_KERNEL $SH_ARCH, $SH_LIBC, wsl=$SH_WSL, privilege=$SH_PRIVILEGE"
    sh_say "pty=$SH_PTY passwd=$SH_PASSWD"
    if [ "$SH_HOME_EXEC" = yes ]; then
        sh_say "home and exec are the same root: $SH_HOME"
    else
        sh_say "home $SH_HOME (noexec); exec $SH_EXEC"
    fi

    # Compose the request: the toolset, plus --with, minus --without, first-seen
    # wins so a name the toolset and --with both carry is installed once.
    sh_mb_wanted=''
    for sh_mb_name in $(sh_toolset_names "$SH_TOOLSET") $(sh_split_on ',' "$SH_WITH"); do
        if sh_in_list "$sh_mb_name" "$(sh_split_on ',' "$SH_WITHOUT")"; then
            continue
        fi
        if sh_in_list "$sh_mb_name" "$sh_mb_wanted"; then
            continue
        fi
        sh_mb_wanted="$sh_mb_wanted $sh_mb_name"
    done

    for sh_mb_name in $sh_mb_wanted; do
        sh_toolchain_ensure "$sh_mb_name" || true
    done

    if [ "$SH_SHIMS" != none ]; then
        sh_shim_build_all "$SH_REPO_DIR/shims"
        sh_shim_write_passwd
        if [ "$SH_NEED_SHIMS" = 1 ]; then
            for sh_mb_shim in fakepty fakepwd; do
                if [ "$(sh_shim_need "$sh_mb_shim")" = yes ] && [ ! -f "$(sh_shims_dir)/$sh_mb_shim.so" ]; then
                    sh_fail "the $sh_mb_shim shim is needed here and could not be built"
                fi
            done
        fi
    fi

    sh_bootstrap_install_shell || true
    sh_env_write
    sh_env_load
    sh_bootstrap_path_line
    sh_bootstrap_install_profile || true

    SH_INSTALLED=$INSTALLED
    SH_ADOPTED=$ADOPTED
    if [ "$SH_JSON" = 1 ]; then
        sh_report_json
    else
        sh_report_text
    fi
    if [ "$SH_FAILURES" -gt 0 ]; then
        return 1
    fi
    return 0
}

if [ -z "$SH_NO_RUN" ]; then
    sandhome_bootstrap_main "$@"
    status=$?
    if [ -n "$SH_FETCH_DIR" ]; then
        rm -rf "$SH_FETCH_DIR" 2>/dev/null || true
    fi
    exit "$status"
fi
