#!/bin/sh
# shim.sh - build and install the two LD_PRELOAD interposers. Sourced.
#
# fakepty makes a pipe-backed shell believe fds 0-2 are a terminal, so readline
# and echo work where there is no /dev/ptmx. fakepwd answers getpwnam/getpwuid
# from a synthetic passwd database for a cage with no /etc/passwd.
#
# ⛔ NEITHER CAN REACH A STATICALLY LINKED BINARY. A static binary carries its own
# libc, so LD_PRELOAD has nothing to interpose into. That is a measurement, not a
# caveat: it is why the ssh server sandhome builds must be dynamically linked.

sh_shims_dir() { printf '%s/shims' "$SH_HOME"; }

# sh_shim_need NAME -> yes when the machine lacks what the shim supplies.
sh_shim_need() {
    case "$1" in
        fakepty) [ "${SH_PTY:-unknown}" = no ] && printf 'yes' || printf 'no' ;;
        fakepwd) [ "${SH_PASSWD:-unknown}" = no ] && printf 'yes' || printf 'no' ;;
        *)       printf 'no' ;;
    esac
}

# sh_shim_build NAME SRC -> compile SRC into $SH_HOME/shims/NAME.so.
sh_shim_build() {
    sh_sb_name=$1
    sh_sb_src=$2
    sh_sb_out="$(sh_shims_dir)/$sh_sb_name.so"
    if [ ! -f "$sh_sb_src" ]; then
        sh_warn "no source at $sh_sb_src"
        return 1
    fi
    if ! sh_have cc && ! sh_have gcc; then
        sh_warn "no C compiler is present, so $sh_sb_name cannot be built"
        return 1
    fi
    sh_sb_cc=cc
    sh_have cc || sh_sb_cc=gcc
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would compile $sh_sb_src into $sh_sb_out"
        return 0
    fi
    mkdir -p "$(sh_shims_dir)" 2>/dev/null || return 1
    if ! "$sh_sb_cc" -shared -fPIC -O2 -o "$sh_sb_out" "$sh_sb_src" 2>/dev/null; then
        sh_warn "$sh_sb_cc could not build $sh_sb_name"
        return 1
    fi
    sh_step "built $sh_sb_out"
    return 0
}

# sh_shim_build_all SRC_DIR -> build whichever shims are needed here. A shim the
# machine does not need is not built, so a normal host gets nothing.
sh_shim_build_all() {
    sh_sba_dir=$1
    sh_sba_built=''
    for sh_sba_name in fakepty fakepwd; do
        sh_sba_need=$(sh_shim_need "$sh_sba_name")
        if [ "$sh_sba_need" != yes ]; then
            sh_step "$sh_sba_name: this machine has $(sh_sba_what "$sh_sba_name"); not needed"
            continue
        fi
        if sh_shim_build "$sh_sba_name" "$sh_sba_dir/$sh_sba_name.c"; then
            # A dry run compiles nothing, so the report must not name a built
            # shim. The report is read from the machine, never from intent.
            if [ "$SH_DRY_RUN" != 1 ]; then
                sh_sba_built="$sh_sba_built $sh_sba_name"
            fi
        fi
    done
    SH_SHIMS_BUILT=${sh_sba_built# }
    export SH_SHIMS_BUILT
    return 0
}

sh_sba_what() {
    case "$1" in
        fakepty) printf 'a pty' ;;
        fakepwd) printf 'a passwd database' ;;
        *)       printf 'what it needs' ;;
    esac
}

# sh_shim_write_passwd -> the synthetic passwd file fakepwd reads, built from the
# account that is running. SANDSSH_PASSWD is the variable the shim already reads;
# env.sh exports it when the shim is loaded.
#
# ⛔ `id -un` CAN FAIL, AND WHEN IT DOES IT PRINTS TO STDERR AND NOTHING TO
# STDOUT. A cage with no /etc/passwd answers exactly that, and naming the entry
# `root` with uid 966 then reads as a passwd file that lies. The name is derived
# from the uid instead, and the uid is what the shim is asked for.
sh_shim_write_passwd() {
    sh_swp_file="$(sh_shims_dir)/passwd"
    sh_swp_uid=$(id -u 2>/dev/null) || sh_swp_uid=0
    sh_swp_gid=$(id -g 2>/dev/null) || sh_swp_gid=0
    sh_swp_user=$(id -un 2>/dev/null) || sh_swp_user=''
    if [ -z "$sh_swp_user" ]; then
        sh_swp_user="user$sh_swp_uid"
    fi
    sh_swp_home=${HOME:-/root}
    sh_swp_shell=${SHELL:-/bin/sh}
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would write $sh_swp_file for $sh_swp_user"
        return 0
    fi
    mkdir -p "$(sh_shims_dir)" 2>/dev/null || return 1
    {
        printf 'root:x:0:0:root:/root:/bin/sh\n'
        if [ "$sh_swp_uid" != 0 ]; then
            printf '%s:x:%s:%s:%s:%s:%s\n' \
                "$sh_swp_user" "$sh_swp_uid" "$sh_swp_gid" "$sh_swp_user" "$sh_swp_home" "$sh_swp_shell"
        fi
        # ⭐ ANY LOGIN NAME A CALLER NAMES IS ADDED TOO. A cage's ssh server looks
        # the login name up before it checks the key, and an account that is not
        # there is refused with "Permission denied (publickey)", which reads as a
        # key problem and is not one. SANDHOME_PASSWD_USERS=agent,deploy adds the
        # names a later session will actually log in as.
        sh_swp_n=1000
        for sh_swp_extra in $(sh_split_on ', ' "${SANDHOME_PASSWD_USERS:-}"); do
            [ -n "$sh_swp_extra" ] || continue
            if [ "$sh_swp_extra" = root ] || [ "$sh_swp_extra" = "$sh_swp_user" ]; then
                continue
            fi
            printf '%s:x:%s:%s:%s:%s:%s\n' \
                "$sh_swp_extra" "$sh_swp_n" "$sh_swp_n" "$sh_swp_extra" "/home/$sh_swp_extra" "$sh_swp_shell"
            mkdir -p "/home/$sh_swp_extra" 2>/dev/null || true
            sh_swp_n=$((sh_swp_n + 1))
        done
    } > "$sh_swp_file"
    # ⛔ THE HOME MUST EXIST OR A SSH SERVER THAT CHDIRS TO IT FAILS, and the
    # failure reads as an auth problem rather than a missing directory.
    [ -d "$sh_swp_home" ] || mkdir -p "$sh_swp_home" 2>/dev/null || true
    return 0
}

# sh_shim_report -> what was needed, what was built, and where.
sh_shim_report() {
    printf 'pty=%s passwd=%s built=%s dir=%s\n' \
        "${SH_PTY:-unknown}" "${SH_PASSWD:-unknown}" \
        "${SH_SHIMS_BUILT:-none}" "$(sh_shims_dir)"
}
