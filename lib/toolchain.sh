#!/bin/sh
# toolchain.sh - the contract every tools/<name>.sh module obeys, and the one
# place that installs, adopts and promotes. Sourced.
#
# A module declares:
#   TC_<name>_DESC        a one-line description for `sandhome toolchains`
#   TC_<name>_BINS        space-separated relative executables to put on PATH
#   TC_<name>_REQUIRES    space-separated toolchains to ensure first
#   tc_<name>_probe       return 0 when a working copy is already here
#   tc_<name>_install     install into $(sh_toolchain_root <name>)
#   tc_<name>_env         write the env fragment (optional)
#   tc_<name>_version     print the version (optional)
#
# ⭐ ADOPT BEFORE INSTALL. A sandbox that already carries a toolchain is the
# common case in this setup, and downloading a second copy of rust only to find
# the first one is how a small exec root fills up. A `probe` that succeeds skips
# the install and writes the env fragment that points at the copy already there.
#
# ⛔ A MODULE IS LOADED BY PATH, and every function it defines is namespaced by
# the module name, because POSIX sh has no namespaces and two modules defining
# `install` would silently shadow each other.

# sh_toolchains_dir -> where the modules live, beside this library.
SH_TOOLCHAIN_LOADED=''
SH_TOOLCHAIN_INSTALLING=''
SH_TOOLCHAIN_VISITING=''
INSTALLED=''
ADOPTED=''

sh_toolchains_dir() {
    if [ -n "${SH_LIB_DIR:-}" ] && [ -d "$SH_LIB_DIR/../tools" ]; then
        printf '%s/../tools' "$SH_LIB_DIR"
        return 0
    fi
    printf '%s/tools' "${SH_REPO_DIR:-.}"
}

sh_toolchain_module() { printf '%s/%s.sh' "$(sh_toolchains_dir)" "$1"; }

# sh_toolchain_available -> every module name, sorted by the shell's own glob.
sh_toolchain_available() {
    for sh_ta_f in "$(sh_toolchains_dir)"/*.sh; do
        [ -f "$sh_ta_f" ] || continue
        sh_ta_b=${sh_ta_f##*/}
        printf '%s ' "${sh_ta_b%.sh}"
    done
}

sh_toolchain_known() {
    sh_tk_want=$1
    for sh_tk_f in "$(sh_toolchains_dir)"/*.sh; do
        [ -f "$sh_tk_f" ] || continue
        sh_tk_b=${sh_tk_f##*/}
        if [ "${sh_tk_b%.sh}" = "$sh_tk_want" ]; then
            return 0
        fi
    done
    return 1
}

# sh_toolchain_load NAME -> source the module once.
SH_TOOLCHAIN_LOADED=''
sh_toolchain_load() {
    case " $SH_TOOLCHAIN_LOADED " in
        *" $1 "*) return 0 ;;
    esac
    sh_tl_file=$(sh_toolchain_module "$1")
    if [ ! -f "$sh_tl_file" ]; then
        sh_warn "no module for toolchain $1"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$sh_tl_file"
    SH_TOOLCHAIN_LOADED="$SH_TOOLCHAIN_LOADED $1"
    return 0
}

# sh_toolchain_probe NAME -> 0 when the toolchain answers already. Loads the
# module, so it is safe to ask about a toolchain before deciding anything.
sh_toolchain_probe() {
    sh_tp_name=$1
    sh_toolchain_load "$sh_tp_name" || return 1
    if ! command -v "tc_${sh_tp_name}_probe" >/dev/null 2>&1; then
        return 1
    fi
    "tc_${sh_tp_name}_probe" >/dev/null 2>&1
}

# sh_toolchain_root_or_default NAME -> the module's home root. The default is
# $SH_HOME_TOOLCHAINS/<name>; a module may override it to adopt an existing tree.
sh_toolchain_root_or_default() {
    sh_trd_name=$1
    sh_toolchain_load "$sh_trd_name" || return 1
    if command -v "tc_${sh_trd_name}_home" >/dev/null 2>&1; then
        "tc_${sh_trd_name}_home"
        return 0
    fi
    sh_toolchain_root "$sh_trd_name"
}

# sh_toolchain_requires NAME -> the modules NAME needs first, space separated.
sh_toolchain_requires() {
    sh_tq_name=$1
    sh_toolchain_load "$sh_tq_name" >/dev/null 2>&1 || { printf ''; return 0; }
    if command -v "tc_${sh_tq_name}_requires" >/dev/null 2>&1; then
        "tc_${sh_tq_name}_requires" 2>/dev/null
        return 0
    fi
    eval "printf '%s' \"\${TC_${sh_tq_name}_REQUIRES:-}\""
    return 0
}

# sh_toolchain_closure NAME -> NAME and everything it transitively requires,
# each once. Iterative on purpose; see sh_toolchain_order.
sh_toolchain_closure() {
    sh_tc_seen=''
    sh_tc_work=$1
    while [ -n "$sh_tc_work" ]; do
        sh_tc_n=${sh_tc_work%% *}
        case "$sh_tc_work" in
            *' '*) sh_tc_work=${sh_tc_work#* } ;;
            *)     sh_tc_work='' ;;
        esac
        [ -n "$sh_tc_n" ] || continue
        case " $sh_tc_seen " in
            *" $sh_tc_n "*) continue ;;
        esac
        sh_tc_seen="$sh_tc_seen $sh_tc_n"
        sh_tc_work="$sh_tc_work $(sh_toolchain_requires "$sh_tc_n")"
    done
    printf '%s' "$sh_tc_seen"
}

# sh_toolchain_order NAME -> the closure in an order where every requirement
# comes before the module that needs it.
#
# ⛔ IT IS ITERATIVE AND NOT A RECURSIVE ENSURE, AND THAT FIXED A REAL BUG.
# `sh_toolchain_ensure` was recursive, and POSIX sh has no `local`: the nested
# call for a requirement overwrote the parent's `sh_te_name`, so the parent then
# probed and installed the REQUIREMENT a second time and never installed itself.
# Measured with c requires d: `d` was installed and adopted, `c` was not touched,
# and the run exited 0. Kahn's algorithm below resolves the order with no
# recursion, and refuses a cycle by listing the names left over.
sh_toolchain_order() {
    sh_to_all=$(sh_toolchain_closure "$1")
    sh_to_remaining=$sh_to_all
    sh_to_order=''
    while [ -n "$sh_to_remaining" ]; do
        sh_to_progress=0
        sh_to_next=''
        for sh_to_n in $sh_to_remaining; do
            sh_to_blocked=0
            for sh_to_r in $(sh_toolchain_requires "$sh_to_n"); do
                if sh_in_list "$sh_to_r" "$sh_to_remaining"; then
                    sh_to_blocked=1
                    break
                fi
            done
            if [ "$sh_to_blocked" = 0 ]; then
                sh_to_order="$sh_to_order $sh_to_n"
                sh_to_progress=1
            else
                sh_to_next="$sh_to_next $sh_to_n"
            fi
        done
        sh_to_remaining=$sh_to_next
        if [ "$sh_to_progress" = 0 ]; then
            sh_fail "toolchain requirements are cyclic at:$(sh_trim "$sh_to_remaining")"
            return 1
        fi
    done
    printf '%s\n' "$sh_to_order"
    return 0
}

# sh_toolchain_install_one NAME -> adopt or install exactly one module, then
# promote it and write its environment. It never calls itself.
sh_toolchain_install_one() {
    sh_te_name=$1
    if ! sh_toolchain_known "$sh_te_name"; then
        sh_fail "unknown toolchain $sh_te_name; run 'sandhome toolchains' for the list"
        return 1
    fi
    sh_toolchain_load "$sh_te_name" || return 1

    # ⛔ LOAD ANY EXISTING ENVIRONMENT BEFORE PROBING. A toolchain whose binary is
    # reached only through its own PATH fragment (go, rust, uv) is invisible on
    # PATH in a fresh shell until that fragment is sourced. Probing first made
    # every second `sandhome install go` download the whole tarball again while a
    # working copy sat in the home.
    sh_env_load

    if sh_toolchain_probe "$sh_te_name"; then
        sh_say "toolchain $sh_te_name: a working copy is already here; adopting it"
        ADOPTED="$ADOPTED $sh_te_name"
    else
        sh_say "toolchain $sh_te_name: not present; installing into $SH_HOME_TOOLCHAINS/$sh_te_name"
        if ! "tc_${sh_te_name}_install"; then
            sh_fail "toolchain $sh_te_name could not be installed"
            return 1
        fi
        INSTALLED="$INSTALLED $sh_te_name"
    fi

    # The exec view, then PATH entries for this module's binaries.
    eval "sh_te_bins=\${TC_${sh_te_name}_BINS:-}"
    if [ -n "$sh_te_bins" ]; then
        # shellcheck disable=SC2086
        sh_promote_toolchain "$sh_te_name" $sh_te_bins || true
    fi
    if command -v "tc_${sh_te_name}_env" >/dev/null 2>&1; then
        "tc_${sh_te_name}_env" || sh_warn "toolchain $sh_te_name wrote no env fragment"
    fi
    sh_env_load
    # ⭐ THE LAST WORD IS A PROBE, NOT AN EXIT CODE. A toolchain that installed
    # "without an error" and does not answer afterwards is the exact claim this
    # tree exists to refuse, and the split root is where it would hide.
    if command -v "tc_${sh_te_name}_probe" >/dev/null 2>&1; then
        if ! "tc_${sh_te_name}_probe" >/dev/null 2>&1; then
            sh_fail "toolchain $sh_te_name installed without an error and still does not run from the exec view"
            return 1
        fi
    fi
    return 0
}

# sh_toolchain_ensure NAME -> ensure NAME and its requirements, in order.
sh_toolchain_ensure() {
    sh_te_root=$1

    if [ "$SH_DRY_RUN" = 1 ]; then
        if ! sh_toolchain_known "$sh_te_root"; then
            sh_fail "unknown toolchain $sh_te_root; run 'sandhome toolchains' for the list"
            return 1
        fi
        for sh_te_d in $(sh_toolchain_order "$sh_te_root"); do
            if sh_toolchain_probe "$sh_te_d"; then
                sh_say "toolchain $sh_te_d: would adopt the working copy already here"
            else
                sh_say "toolchain $sh_te_d: would install into $SH_HOME_TOOLCHAINS/$sh_te_d"
            fi
        done
        return 0
    fi

    sh_te_order=$(sh_toolchain_order "$sh_te_root") || return 1
    for sh_te_item in $sh_te_order; do
        sh_toolchain_install_one "$sh_te_item" || return 1
    done
    return 0
}

# sh_toolchain_version NAME -> the version string, or nothing.
sh_toolchain_version() {
    sh_tv_name=$1
    sh_toolchain_load "$sh_tv_name" >/dev/null 2>&1 || { printf ''; return 0; }
    if command -v "tc_${sh_tv_name}_version" >/dev/null 2>&1; then
        "tc_${sh_tv_name}_version" 2>/dev/null
        return 0
    fi
    printf ''
}

# sh_toolchain_bins NAME -> the declared relative executables.
sh_toolchain_bins() {
    sh_tb_name=$1
    sh_toolchain_load "$sh_tb_name" >/dev/null 2>&1 || { printf ''; return 0; }
    eval "printf '%s' \"\${TC_${sh_tb_name}_BINS:-}\""
}
