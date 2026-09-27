#!/bin/sh
# common.sh - logging, small helpers and the one appender, for every sandhome
# script. POSIX sh only: no `local`, no `[[`, no arrays, no `$'...'`, no `a && b
# || c`. Sourced, never executed.
#
# WHY THE HELPERS ARE HERE AND NOT IN EACH SCRIPT. A bootstrap runs on a userland
# that may be missing tr, sed, grep, find and install; every one of those has an
# equivalent below that uses only the shell. A helper copied into four scripts is
# four behaviours by the third edit.

# ---------------------------------------------------------------- reporting --
# Everything a person reads goes to stderr. stdout belongs to the caller: the
# final report, a `sandhome env` block, or a machine-readable object.
: "${SH_SELF:=sandhome}"
: "${SH_FAILURES:=0}"
: "${SH_SKIPPED:=}"
: "${SH_DRY_RUN:=0}"

sh_say()  { printf '%s: %s\n'   "$SH_SELF" "$*" >&2; }
sh_step() { printf '%s:   %s\n' "$SH_SELF" "$*" >&2; }
sh_warn() { printf '%s: [!] %s\n' "$SH_SELF" "$*" >&2; }
sh_die()  { printf '%s: [-] %s\n' "$SH_SELF" "$*" >&2; exit 2; }
sh_fail() { printf '%s: [-] %s\n' "$SH_SELF" "$*" >&2; SH_FAILURES=$((SH_FAILURES + 1)); }

sh_reset_failures() { SH_FAILURES=0; }
sh_failures() { printf '%s' "$SH_FAILURES"; }

# sh_note NAME appends a logical name to the skipped list once.
sh_skip() {
    case " $SH_SKIPPED " in
        *" $1 "*) ;;
        *) SH_SKIPPED="$SH_SKIPPED $1" ;;
    esac
}

# ------------------------------------------------------------ shell helpers --
# sh_have NAME -> the name resolves to something runnable. `command -v` answers
# about a function and an alias too, but a non-interactive sh has neither and
# this file defines no function named after a tool, so the simple form is right
# here and would not be inside somebody's interactive shell.
sh_have() { command -v "$1" >/dev/null 2>&1; }

# sh_first_line COMMAND... -> the command's first line, or nothing. `head -1`
# without head, which Photon and openSUSE minimal images do not always carry.
# ⛔ `read` RETURNS NON-ZERO AT EOF WITHOUT A NEWLINE and still sets the variable;
# testing read's status threw the answer away. `printf 'a'` and a file that does
# not end in a newline are both ordinary, and every caller here read nothing
# while the command itself ran fine.
sh_first_line() {
    "$@" 2>/dev/null | {
        read -r sh_fl_line || :
        printf '%s' "$sh_fl_line"
    }
}

# sh_first_word COMMAND... -> the first whitespace-separated word of the first
# line, with the same newline caveat as sh_first_line.
sh_first_word() {
    "$@" 2>/dev/null | {
        read -r sh_fw_word _ || :
        printf '%s' "$sh_fw_word"
    }
}

# sh_split_on SEPARATORS STRING -> STRING with each separator replaced by a
# space. This is `tr`'s job, and Photon carries no tr.
sh_split_on() {
    sh_so_seps=$1
    sh_so_in=$2
    sh_so_out=''
    while [ -n "$sh_so_in" ]; do
        sh_so_head=${sh_so_in%%[!"$sh_so_seps"]*}
        if [ -n "$sh_so_head" ]; then
            sh_so_in=${sh_so_in#"$sh_so_head"}
            sh_so_out="$sh_so_out "
            continue
        fi
        sh_so_word=${sh_so_in%%["$sh_so_seps"]*}
        sh_so_out="$sh_so_out$sh_so_word"
        sh_so_in=${sh_so_in#"$sh_so_word"}
    done
    printf '%s' "$sh_so_out"
}

sh_commas_to_spaces() { sh_split_on ',' "$1"; }

# sh_in_list ITEM LIST, where LIST may be space, comma or pipe separated.
sh_in_list() {
    case " $(sh_split_on ',|' "$2") " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# sh_trim STRING -> STRING with leading and trailing blanks removed.
sh_trim() {
    sh_tr_out=$1
    sh_tr_out=${sh_tr_out#"${sh_tr_out%%[![:space:]]*}"}
    sh_tr_out=${sh_tr_out%"${sh_tr_out##*[![:space:]]}"}
    printf '%s' "$sh_tr_out"
}

# sh_sq_quote STRING -> STRING wrapped for safe re-reading by a shell. A single
# quote cannot appear inside single quotes, so the quote is closed, escaped and
# reopened. Used for every path written into env.sh and profile.sh; a home with
# a space or an apostrophe in it otherwise breaks the file it is written into.
sh_sq_quote() {
    sh_sq_out=''
    sh_sq_rest=$1
    while [ -n "$sh_sq_rest" ]; do
        case "$sh_sq_rest" in
            *"'"*)
                sh_sq_out="$sh_sq_out${sh_sq_rest%%\'*}'\\''"
                sh_sq_rest=${sh_sq_rest#*\'}
                ;;
            *)
                sh_sq_out="$sh_sq_out$sh_sq_rest"
                sh_sq_rest=''
                ;;
        esac
    done
    printf "'%s'" "$sh_sq_out"
}

# sh_lex_normalize PATH -> PATH with `.` and `..` resolved textually. It does NOT
# touch the filesystem, so it answers for a path that does not exist yet, which
# is exactly what a mirrored symlink target needs. `..` at the root of a relative
# path is kept, because that path has already left its tree.
sh_lex_normalize() {
    sh_lz_abs=0
    case "$1" in /*) sh_lz_abs=1 ;; esac
    sh_lz_out=''
    sh_lz_rest=$1
    while [ -n "$sh_lz_rest" ]; do
        case "$sh_lz_rest" in
            */*) sh_lz_seg=${sh_lz_rest%%/*}; sh_lz_rest=${sh_lz_rest#*/} ;;
            *)   sh_lz_seg=$sh_lz_rest; sh_lz_rest='' ;;
        esac
        case "$sh_lz_seg" in
            ''|.) continue ;;
            ..)
                case "$sh_lz_out" in
                    '') [ "$sh_lz_abs" = 1 ] || sh_lz_out='..' ;;
                    */*) sh_lz_out=${sh_lz_out%/*} ;;
                    *)   sh_lz_out='' ;;
                esac
                ;;
            *) sh_lz_out=${sh_lz_out:+$sh_lz_out/}$sh_lz_seg ;;
        esac
    done
    if [ "$sh_lz_abs" = 1 ]; then
        printf '/%s' "$sh_lz_out"
    else
        printf '%s' "$sh_lz_out"
    fi
}

# sh_abs_path PATH -> PATH made absolute against PWD, without readlink -f, which
# BusyBox and older BSD userlands do not all carry.
sh_abs_path() {
    case "$1" in
        /*) printf '%s' "$1"; return 0 ;;
    esac
    printf '%s/%s' "${PWD:-.}" "$1"
}

# sh_script_dir -> the directory of $0, or nothing when $0 has none (a script
# read from a pipe reports `sh` or the current directory, neither of which is
# where the file is). Answering nothing is honest.
sh_script_dir() {
    case "$0" in
        */*) ;;
        *)
            # A bare `$0` is a filename in the working directory when a person
            # typed `sh bootstrap.sh`, and the name of the interpreter when the
            # script arrived on stdin. Only a file answers as one.
            if [ -f "$0" ]; then
                ( CDPATH='' cd -- . && pwd )
            fi
            return 0
            ;;
    esac
    if [ ! -f "$0" ]; then
        printf ''
        return 0
    fi
    ( CDPATH='' cd -- "${0%/*}" && pwd )
}

# sh_free_mb DIR -> free megabytes on the filesystem holding DIR, or nothing.
# `df -Pk` is the POSIX-visible form; the field is read with the shell so a
# userland without awk still answers.
sh_free_mb() {
    df -Pk "$1" 2>/dev/null | {
        if read -r sh_df_dev sh_df_1 sh_df_used sh_df_free sh_df_rest; then
            # the header line is skipped by reading a second line
            if read -r sh_df_dev sh_df_1 sh_df_used sh_df_free sh_df_rest; then
                case "$sh_df_free" in
                    ''|*[!0-9]*) printf '' ;;
                    *) printf '%s' $((sh_df_free / 1024)) ;;
                esac
            fi
        fi
    }
}

# sh_total_mb DIR -> total megabytes, for the space report.
sh_total_mb() {
    df -Pk "$1" 2>/dev/null | {
        if read -r sh_df_dev sh_df_total sh_df_used sh_df_free sh_df_rest; then
            if read -r sh_df_dev sh_df_total sh_df_used sh_df_free sh_df_rest; then
                case "$sh_df_total" in
                    ''|*[!0-9]*) printf '' ;;
                    *) printf '%s' $((sh_df_total / 1024)) ;;
                esac
            fi
        fi
    }
}

# sh_json_escape STRING -> STRING safe inside a JSON string. Only the five
# mandatory escapes and control characters are handled; sandhome only ever puts
# identifiers, paths and counts through here.
sh_json_escape() {
    sh_je_in=$1
    sh_je_out=''
    while [ -n "$sh_je_in" ]; do
        sh_je_c=${sh_je_in%"${sh_je_in#?}"}
        sh_je_in=${sh_je_in#?}
        case "$sh_je_c" in
            '"')  sh_je_out="$sh_je_out\\\"" ;;
            '\')  sh_je_out="$sh_je_out\\\\" ;;
            '	')  sh_je_out="$sh_je_out\\t" ;;
            *)    sh_je_out="$sh_je_out$sh_je_c" ;;
        esac
    done
    printf '%s' "$sh_je_out"
}

# --------------------------------------------------------------- appenders --
# ⭐ ONE APPENDER FOR EVERY FILE THIS TOOL WRITES TO. Two copies of "add this
# line unless it is already there" is how the two drift, and the second copy is
# always the one that forgets the marker or compares a prefix. It CREATES the
# file, so a caller that must not bring a file into being tests for it first.
#
# SH_ADDED is 1 when this call wrote the line, 0 when it was already present.
sh_append_once() {
    sh_ao_file=$1
    sh_ao_line=$2
    SH_ADDED=0
    : >> "$sh_ao_file"
    while read -r sh_ao_existing; do
        if [ "$sh_ao_existing" = "$sh_ao_line" ]; then
            return 0
        fi
    done < "$sh_ao_file"
    printf '\n# Added by %s.\n%s\n' "$SH_SELF" "$sh_ao_line" >> "$sh_ao_file"
    SH_ADDED=1
    return 0
}

# ⛔ BASH READS THE FIRST OF THREE FILES AND STOPS. Where ~/.bash_profile or
# ~/.bash_login exists - the RHEL family's skeleton ships one - bash never reads
# ~/.profile, so a line written only there does nothing for the login shell that
# account actually gets. NEITHER OF THE TWO IS CREATED: creating ~/.bash_profile
# would itself stop bash reading ~/.profile, where every other shell looks.
sh_append_login() {
    sh_al_line=$1
    sh_al_what=$2
    sh_append_once "$HOME/.profile" "$sh_al_line"
    if [ "$SH_ADDED" = 1 ]; then
        sh_step "added $sh_al_what to $HOME/.profile"
    fi
    for sh_al_file in "$HOME/.bash_profile" "$HOME/.bash_login"; do
        if [ -f "$sh_al_file" ]; then
            sh_append_once "$sh_al_file" "$sh_al_line"
            if [ "$SH_ADDED" = 1 ]; then
                sh_step "added $sh_al_what to $sh_al_file"
            fi
        fi
    done
}

# sh_append_rc LINE -> the same, for ~/.bashrc and ~/.zshrc when they exist,
# because many non-login interactive shells read those and not ~/.profile.
sh_append_rc() {
    sh_ar_line=$1
    sh_ar_what=$2
    for sh_ar_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.kshrc"; do
        if [ -f "$sh_ar_file" ]; then
            sh_append_once "$sh_ar_file" "$sh_ar_line"
            if [ "$SH_ADDED" = 1 ]; then
                sh_step "added $sh_ar_what to $sh_ar_file"
            fi
        fi
    done
}

# sh_run DESCRIPTION COMMAND... -> run unless --dry-run, report the step.
sh_run() {
    sh_r_what=$1
    shift
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would run: $*"
        return 0
    fi
    sh_step "$sh_r_what"
    "$@"
}
