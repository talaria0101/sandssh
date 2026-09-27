#!/bin/sh
# space.sh - where files may live, and where they may run. Sourced.
#
# THE MEASUREMENT THIS EXISTS FOR. A sandbox can mount a directory rw and still
# refuse execve(2) on it, while allowing mmap(PROT_EXEC) - so a shared library
# read from there loads, and a copied binary in it will not run. `mount` does not
# have to say noexec: the refusal can come from a sandbox policy that is invisible
# in /proc/mounts. The only reliable answer is to try it.
#
# WHAT THAT MEANS FOR A TOOLCHAIN. Data (stdlib, GOROOT, .rlib, .so) may live on
# the big read-only-in-effect home directory. Executables (rustc, cargo, go, node,
# the bundled linker) may not: they need an exec-capable mount, and so does every
# build script, proc-macro and test binary a build produces.
#
# So the plan is two roots:
#   SH_HOME  persistent data, exactly where it was asked for. May be noexec.
#   SH_EXEC  the exec-capable root. Small is fine; only executables and build
#            output are promoted here, everything else is symlinked back.
# When SH_HOME is itself exec-capable the two collapse and nothing is promoted.

: "${SH_MIN_EXEC_MB:=128}"
: "${SH_MIN_HOME_MB:=256}"
SH_TAB=$(printf '\t')

# sh_dir_writable DIR -> 0 when a file can be created in DIR.
sh_dir_writable() {
    [ -d "$1" ] || return 1
    sh_dw_probe="$1/.sandhome.w.$$"
    if ( : > "$sh_dw_probe" ) 2>/dev/null; then
        rm -f "$sh_dw_probe" 2>/dev/null
        return 0
    fi
    rm -f "$sh_dw_probe" 2>/dev/null
    return 1
}

# sh_exec_probe DIR -> 0 when a binary can actually be executed from DIR.
# ⛔ NOT A CHECK OF MOUNT OPTIONS. The probe is a real exec of a real file; a
# policy that refuses execve does not have to show up in /proc/mounts, and a
# mount that says noexec can still allow it on some kernels.
sh_exec_probe() {
    sh_ep_dir=$1
    [ -d "$sh_ep_dir" ] || return 1
    sh_ep_file="$sh_ep_dir/.sandhome.exec.$$"
    if ! printf '#!/bin/sh\nexit 0\n' > "$sh_ep_file" 2>/dev/null; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 1
    fi
    chmod 0700 "$sh_ep_file" 2>/dev/null || true
    if "$sh_ep_file" >/dev/null 2>&1; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 0
    fi
    rm -f "$sh_ep_file" 2>/dev/null
    return 1
}

# sh_mount_opts DIR -> the mount options for the filesystem holding DIR, or
# nothing. This is the cheap answer shown in the report; it is never the answer
# used to decide, because it can be wrong.
sh_mount_opts() {
    if [ -r /proc/mounts ]; then
        sh_mo_want=$1
        sh_mo_best=''
        sh_mo_len=0
        while read -r sh_mo_dev sh_mo_point sh_mo_fs sh_mo_opts sh_mo_a sh_mo_b; do
            case "$sh_mo_want" in
                "$sh_mo_point"|"$sh_mo_point"/*)
                    if [ "${#sh_mo_point}" -gt "$sh_mo_len" ]; then
                        sh_mo_len=${#sh_mo_point}
                        sh_mo_best=$sh_mo_opts
                    fi
                    ;;
            esac
        done < /proc/mounts
        if [ -n "$sh_mo_best" ]; then
            printf '%s' "$sh_mo_best"
            return 0
        fi
    fi
    printf ''
}

# sh_home_default -> the persistent root, honouring the environment. XDG first
# when it is set, then ~/.local/share, then a plain ~/.sandhome for a userland
# with no XDG convention at all.
sh_home_default() {
    if [ -n "${SANDHOME_HOME:-}" ]; then
        printf '%s' "$SANDHOME_HOME"
        return 0
    fi
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s/sandhome' "$XDG_DATA_HOME"
        return 0
    fi
    if [ -n "${HOME:-}" ]; then
        printf '%s/.local/share/sandhome' "$HOME"
        return 0
    fi
    printf '/tmp/sandhome'
}

# sh_exec_candidates -> the places tried for the exec root, best first. The
# environment override wins, then the home itself, then every writable tmpfs that
# is usually tmpfs, then a directory under the home.
sh_exec_candidates() {
    if [ -n "${SANDHOME_EXEC:-}" ]; then
        printf '%s ' "$SANDHOME_EXEC"
    fi
    printf '%s ' "$SH_HOME"
    printf '%s ' /dev/shm
    printf '%s ' /tmp
    if [ -n "$(id -u 2>/dev/null)" ] && [ -d "/run/user/$(id -u)" ]; then
        printf '%s ' "/run/user/$(id -u)"
    fi
    if [ -n "${HOME:-}" ]; then
        printf '%s ' "$HOME/.cache/sandhome/exec"
    fi
    printf '%s' /var/tmp
}

# sh_space_plan -> set SH_HOME and SH_EXEC, create both, and export them. The
# exec root is the first candidate that is writable and actually runs a file;
# free space prefers a candidate with room but does not disqualify the only one,
# because a small exec root that works beats a large one that does not.
sh_space_plan() {
    SH_HOME=$(sh_home_default)
    SH_EXEC=''
    SH_HOME_EXEC=no

    if ! mkdir -p "$SH_HOME" 2>/dev/null; then
        sh_die "cannot create the home root at $SH_HOME; pass SANDHOME_HOME"
    fi
    if sh_exec_probe "$SH_HOME"; then
        SH_HOME_EXEC=yes
    fi

    sh_sp_first_working=''
    sh_sp_first_roomy=''
    sh_sp_explicit_ok=0
    for sh_sp_candidate in $(sh_exec_candidates); do
        [ -n "$sh_sp_candidate" ] || continue
        if ! mkdir -p "$sh_sp_candidate" 2>/dev/null; then
            continue
        fi
        if ! sh_dir_writable "$sh_sp_candidate"; then
            continue
        fi
        if ! sh_exec_probe "$sh_sp_candidate"; then
            continue
        fi
        if [ -n "${SANDHOME_EXEC:-}" ] && [ "$sh_sp_candidate" = "$SANDHOME_EXEC" ]; then
            sh_sp_explicit_ok=1
        fi
        if [ -z "$sh_sp_first_working" ]; then
            sh_sp_first_working=$sh_sp_candidate
        fi
        sh_sp_free=$(sh_free_mb "$sh_sp_candidate")
        case "$sh_sp_free" in
            ''|*[!0-9]*) sh_sp_free=0 ;;
        esac
        if [ "$sh_sp_free" -ge "$SH_MIN_EXEC_MB" ] && [ -z "$sh_sp_first_roomy" ]; then
            sh_sp_first_roomy=$sh_sp_candidate
        fi
    done

    # ⭐ THE TWO ROOTS COLLAPSE ONLY WHEN NOTHING WAS ASKED FOR EXPLICITLY. An
    # operator who named SANDHOME_EXEC has said where executables must go, and
    # silently overriding that with the home root is how a small root becomes a
    # surprise. A named root that cannot be used is refused by name rather than
    # swapped for a different one.
    if [ -n "${SANDHOME_EXEC:-}" ]; then
        if [ "$sh_sp_explicit_ok" = 1 ]; then
            SH_EXEC=$SANDHOME_EXEC
        else
            sh_die "SANDHOME_EXEC=$SANDHOME_EXEC is not writable or does not allow exec"
        fi
    elif [ "$SH_HOME_EXEC" = yes ]; then
        SH_EXEC=$SH_HOME
    elif [ -n "$sh_sp_first_roomy" ]; then
        SH_EXEC=$sh_sp_first_roomy
    elif [ -n "$sh_sp_first_working" ]; then
        SH_EXEC=$sh_sp_first_working
        sh_warn "no candidate had ${SH_MIN_EXEC_MB}MB free; using $SH_EXEC anyway"
    fi

    if [ -z "$SH_EXEC" ]; then
        sh_die "no writable mount here both allows exec and can be written; set SANDHOME_EXEC to one"
    fi

    SH_EXEC_BIN="$SH_EXEC/bin"
    SH_EXEC_VIEWS="$SH_EXEC/views"
    SH_HOME_TOOLCHAINS="$SH_HOME/toolchains"
    SH_HOME_TMP="$SH_HOME/tmp"
    mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME_TOOLCHAINS" "$SH_HOME_TMP" 2>/dev/null || \
        sh_die "cannot create the sandhome directories below $SH_HOME and $SH_EXEC"

    export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP SH_HOME_EXEC
    return 0
}

# sh_space_need MB [WHERE] -> refuse to proceed when there is plainly not enough
# room for the named install. WHERE is `exec`, `home` or `both` (default both).
sh_space_need() {
    sh_sn_mb=$1
    sh_sn_where=${2:-both}
    case "$sh_sn_where" in
        exec|both)
            sh_sn_free=$(sh_free_mb "$SH_EXEC")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_EXEC has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the exec root"
                return 1
            fi
            ;;
    esac
    case "$sh_sn_where" in
        home|both)
            sh_sn_free=$(sh_free_mb "$SH_HOME")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_HOME has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the home root"
                return 1
            fi
            ;;
    esac
    return 0
}

# sh_is_exec_file PATH -> 0 for a regular file that must be COPIED into an exec
# view rather than symlinked. ⛔ A SHARED OBJECT IS NOT ONE: mmap(PROT_EXEC) from
# a noexec mount is allowed even where execve is not, which is the measurement
# this whole split rests on, and copying a 144MB librustc_driver or a 191MB
# libLLVM would not fit on the small root it would be copied to.
sh_is_exec_file() {
    [ -f "$1" ] || return 1
    [ -x "$1" ] || return 1
    case "$1" in
        *.so|*.so.*|*.dylib|*.dll|*.a|*.rlib|*.rmeta|*.o) return 1 ;;
    esac
    return 0
}

# sh_promote_tree SRC DEST -> mirror SRC into DEST. Directories are recreated,
# executable files are COPIED (they must be able to execve), and everything else
# is symlinked back to SRC. A copy that fails falls back to a symlink and warns,
# because a run that half-answers is worse than one that names the gap.
#
# ⛔ IT IS A QUEUE AND NOT RECURSION, AND THAT IS NOT A STYLE CHOICE. POSIX sh has
# no `local`, so a recursive function's variables are GLOBALS: the recursive call
# for a subdirectory overwrote this call's source, destination and basename, and
# the loop then copied the remaining files to paths built from the child's names.
# Measured on the Go tree: 32 ".sh" files failed to copy and `go` never landed in
# the view at all, while every message blamed the file and not the walk.
sh_promote_tree() {
    sh_pt_src=$1
    sh_pt_dst=$2
    if [ ! -d "$sh_pt_src" ]; then
        return 0
    fi
    sh_pt_root_src=$(sh_lex_normalize "$sh_pt_src")
    sh_pt_root_dst=$(sh_lex_normalize "$sh_pt_dst")
    mkdir -p "$sh_pt_dst" 2>/dev/null || return 1
    sh_pt_tmp=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_pt_tmp" 2>/dev/null || return 1
    sh_pt_queue="$sh_pt_tmp/.promote.$$"
    printf '%s\t%s\n' "$sh_pt_src" "$sh_pt_dst" > "$sh_pt_queue" 2>/dev/null || return 1
    while IFS="$SH_TAB" read -r sh_pt_s sh_pt_d; do
        [ -n "$sh_pt_s" ] || continue
        for sh_pt_e in "$sh_pt_s"/* "$sh_pt_s"/.[!.]* "$sh_pt_s"/..?*; do
            [ -e "$sh_pt_e" ] || [ -L "$sh_pt_e" ] || continue
            sh_pt_b=${sh_pt_e##*/}
            if [ -d "$sh_pt_e" ] && [ ! -L "$sh_pt_e" ]; then
                mkdir -p "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                printf '%s\t%s\n' "$sh_pt_e" "$sh_pt_d/$sh_pt_b" >> "$sh_pt_queue"
                continue
            fi
            # ⛔ A SYMLINK WHOSE TARGET IS IN THIS TREE IS MIRRORED, NOT RESOLVED,
            # AND THAT FIXED A BROKEN npm. Copying the link's target under the
            # link's basename moves it: node's bin/npm -> ../lib/node_modules/
            # npm/bin/npm-cli.js has a relative `require('../lib/cli.js')`, and a
            # copy at bin/npm looked for bin/../lib/cli.js and died. A symlink to
            # the home does not help either: the kernel refuses execve on a
            # shebang script whose inode is on a noexec mount. Pointing the link
            # at the mirrored copy keeps the script on the exec root and keeps
            # every relative path inside the tree.
            if [ -L "$sh_pt_e" ] && sh_have readlink; then
                sh_pt_t=$(readlink "$sh_pt_e" 2>/dev/null)
                case "$sh_pt_t" in
                    '') sh_pt_abs='' ;;
                    /*) sh_pt_abs=$(sh_lex_normalize "$sh_pt_t") ;;
                    *)  sh_pt_abs=$(sh_lex_normalize "$sh_pt_s/$sh_pt_t") ;;
                esac
                case "$sh_pt_abs" in
                    "$sh_pt_root_src"/*)
                        if ln -sfn "$sh_pt_root_dst/${sh_pt_abs#"$sh_pt_root_src"/}" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                            continue
                        fi
                        ;;
                esac
            fi
            if sh_is_exec_file "$sh_pt_e"; then
                if cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                    chmod 0755 "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                else
                    sh_warn "could not copy $sh_pt_e into the exec view; symlinking it instead, and it will not run"
                    ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                fi
            else
                ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
            fi
        done
    done < "$sh_pt_queue"
    rm -f "$sh_pt_queue" 2>/dev/null
    return 0
}

# sh_toolchain_root NAME -> where toolchain NAME's data lives.
sh_toolchain_root() { printf '%s/%s' "$SH_HOME_TOOLCHAINS" "$1"; }

# sh_toolchain_view NAME -> where toolchain NAME's exec view lives.
sh_toolchain_view() { printf '%s/%s' "$SH_EXEC_VIEWS" "$1"; }

# sh_promote_toolchain NAME BIN_REL... -> build the exec view for NAME and put
# every named relative executable on PATH under its basename. When the home is
# already exec-capable the tree needs no mirror, but the bins are still linked:
# the PATH entry is how `sandhome` and the env file find the tool, and skipping
# it left a toolchain installed, reported present in the home, and absent from
# every shell.
sh_promote_toolchain() {
    sh_ptc_name=$1
    shift
    sh_ptc_root=$(sh_toolchain_root "$sh_ptc_name")
    sh_ptc_view=$(sh_toolchain_view "$sh_ptc_name")
    if [ "$SH_HOME_EXEC" = yes ]; then
        sh_ptc_view=$sh_ptc_root
    else
        sh_promote_tree "$sh_ptc_root" "$sh_ptc_view" || sh_fail "could not build the exec view for $sh_ptc_name"
    fi
    for sh_ptc_rel in "$@"; do
        sh_ptc_src="$sh_ptc_view/$sh_ptc_rel"
        sh_ptc_bin=${sh_ptc_rel##*/}
        if [ -e "$sh_ptc_src" ] || [ -L "$sh_ptc_src" ]; then
            mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
            ln -sfn "$sh_ptc_src" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || true
        fi
    done
    SH_TOOLCHAIN_VIEW=$sh_ptc_view
    export SH_TOOLCHAIN_VIEW
    return 0
}

# sh_space_report -> one line per root, and the mounts that were tried. This is
# what `sandhome space` prints and what the bootstrap says when it had to split.
sh_space_report() {
    printf 'home=%s\n' "$SH_HOME"
    printf 'home_exec=%s\n' "$SH_HOME_EXEC"
    printf 'home_mount=%s\n' "$(sh_mount_opts "$SH_HOME")"
    printf 'home_free_mb=%s\n' "$(sh_free_mb "$SH_HOME")"
    printf 'home_total_mb=%s\n' "$(sh_total_mb "$SH_HOME")"
    printf 'exec=%s\n' "$SH_EXEC"
    printf 'exec_mount=%s\n' "$(sh_mount_opts "$SH_EXEC")"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "$SH_EXEC")"
    printf 'exec_total_mb=%s\n' "$(sh_total_mb "$SH_EXEC")"
    printf 'min_exec_mb=%s\n' "$SH_MIN_EXEC_MB"
}

# sh_space_probe_report -> every candidate tried, with the real answer for each.
# This is the report that explains a split decision, and the one to read when a
# toolchain would not run.
sh_space_probe_report() {
    for sh_spr_c in $(sh_exec_candidates); do
        [ -n "$sh_spr_c" ] || continue
        sh_spr_w=no
        sh_spr_x=no
        sh_dir_writable "$sh_spr_c" && sh_spr_w=yes
        sh_exec_probe "$sh_spr_c" && sh_spr_x=yes
        printf 'candidate=%s writable=%s exec=%s mount=%s free_mb=%s\n' \
            "$sh_spr_c" "$sh_spr_w" "$sh_spr_x" \
            "$(sh_mount_opts "$sh_spr_c")" "$(sh_free_mb "$sh_spr_c")"
    done
}

# sh_space_gc [DAYS] -> remove work directories older than DAYS (default 7) and
# every staging directory. A bootstrap leaves staging behind when it is killed,
# and on a small exec root that is the difference between the next install
# fitting and not. Named so a caller can see exactly what may be deleted.
sh_space_gc() {
    sh_gc_days=${1:-7}
    sh_gc_removed=0
    # The named staging areas are ours and are always safe to clear.
    for sh_gc_dir in "$SH_HOME/.staging" "$SH_EXEC/.staging"; do
        [ -d "$sh_gc_dir" ] || continue
        for sh_gc_e in "$sh_gc_dir"/* "$sh_gc_dir"/.[!.]*; do
            [ -e "$sh_gc_e" ] || continue
            rm -rf "$sh_gc_e" 2>/dev/null && sh_gc_removed=$((sh_gc_removed + 1))
        done
    done
    # ⛔ AGE IS CHECKED WITH find AND NOT ASSUMED. Without find the temp area is
    # left alone and that is said out loud, rather than deleted wholesale:
    # another bootstrap may be holding a directory in it right now.
    if [ -d "$SH_HOME_TMP" ]; then
        if sh_have find; then
            for sh_gc_e in "$SH_HOME_TMP"/* "$SH_HOME_TMP"/.[!.]*; do
                [ -e "$sh_gc_e" ] || continue
                if [ -n "$(find "$sh_gc_e" -maxdepth 0 -mtime +"$sh_gc_days" 2>/dev/null)" ]; then
                    rm -rf "$sh_gc_e" 2>/dev/null && sh_gc_removed=$((sh_gc_removed + 1))
                fi
            done
        else
            sh_warn "no find; leaving $SH_HOME_TMP alone rather than deleting a running bootstrap's work"
        fi
    fi
    printf '%s' "$sh_gc_removed"
}
