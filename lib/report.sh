#!/bin/sh
# report.sh - the report read from the machine, in text and in JSON. Sourced.
#
# ⭐ THE REPORT IS READ FROM THE MACHINE, NOT FROM WHAT WAS ASKED FOR. A line
# claiming a tool is present because an install command exited 0 is the class of
# claim this tree keeps finding to be false. Every line below probes.

SH_INSTALLED=''
SH_ADOPTED=''

sh_lead() { printf '%s' "${1# }"; }

# sh_toolchain_status NAME -> present|absent
sh_toolchain_status() {
    if sh_toolchain_probe "$1"; then
        printf 'present'
    else
        printf 'absent'
    fi
}

# sh_report_text -> the human report on stdout. Everything else is stderr.
sh_report_text() {
    printf 'os=%s\n'          "$SH_OS_ID"
    printf 'kernel=%s\n'      "$SH_KERNEL"
    printf 'arch=%s\n'        "$SH_ARCH"
    printf 'libc=%s\n'        "$SH_LIBC"
    printf 'wsl=%s\n'         "$SH_WSL"
    printf 'privilege=%s\n'   "$SH_PRIVILEGE"
    printf 'provider=%s\n'    "${SH_PROVIDER:-none}"
    printf 'pty=%s\n'         "$SH_PTY"
    printf 'passwd=%s\n'      "$SH_PASSWD"
    printf 'home=%s\n'        "$SH_HOME"
    printf 'home_exec=%s\n'   "$SH_HOME_EXEC"
    printf 'exec=%s\n'        "$SH_EXEC"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "$SH_EXEC")"
    printf 'installed=%s\n'   "$(sh_lead "$SH_INSTALLED")"
    printf 'adopted=%s\n'     "$(sh_lead "$SH_ADOPTED")"
    printf 'shims=%s\n'       "$(sh_lead "${SH_SHIMS_BUILT:-}")"
    for sh_rt_name in $(sh_toolchain_available); do
        printf 'toolchain.%s=%s\n' "$sh_rt_name" "$(sh_toolchain_version "$sh_rt_name")"
    done
    printf 'failures=%s\n' "$SH_FAILURES"
}

# sh_report_json -> one JSON object. Only identifiers, names and counts reach
# it; every free-text message went to stderr.
sh_report_json() {
    printf '{'
    printf '"schema":"sandhome/1"'
    printf ',"os":"%s","kernel":"%s","arch":"%s","libc":"%s","wsl":"%s"' \
        "$(sh_json_escape "$SH_OS_ID")" "$(sh_json_escape "$SH_KERNEL")" \
        "$(sh_json_escape "$SH_ARCH")" "$(sh_json_escape "$SH_LIBC")" \
        "$(sh_json_escape "$SH_WSL")"
    printf ',"privilege":"%s","provider":"%s","pty":"%s","passwd":"%s"' \
        "$(sh_json_escape "$SH_PRIVILEGE")" "$(sh_json_escape "${SH_PROVIDER:-none}")" \
        "$(sh_json_escape "$SH_PTY")" "$(sh_json_escape "$SH_PASSWD")"
    printf ',"home":"%s","home_exec":"%s","exec":"%s","exec_free_mb":"%s"' \
        "$(sh_json_escape "$SH_HOME")" "$(sh_json_escape "$SH_HOME_EXEC")" \
        "$(sh_json_escape "$SH_EXEC")" "$(sh_json_escape "$(sh_free_mb "$SH_EXEC")")"
    printf ',"installed":"%s","adopted":"%s","shims":"%s"' \
        "$(sh_json_escape "$(sh_lead "$SH_INSTALLED")")" \
        "$(sh_json_escape "$(sh_lead "$SH_ADOPTED")")" \
        "$(sh_json_escape "$(sh_lead "${SH_SHIMS_BUILT:-}")")"
    printf ',"failures":%s}\n' "$SH_FAILURES"
}

# sh_doctor -> probe the things a working sandhome must have and report. It
# never repairs; the bootstrap does that. Exit status is the number of hard
# failures.
sh_doctor() {
    sh_doc_fail=0
    sh_doctor_check() {
        sh_dc_name=$1
        sh_dc_got=$2
        sh_dc_want=$3
        if [ "$sh_dc_got" = "$sh_dc_want" ]; then
            printf 'ok   %s=%s\n' "$sh_dc_name" "$sh_dc_got"
        else
            printf 'FAIL %s=%s (wanted %s)\n' "$sh_dc_name" "$sh_dc_got" "$sh_dc_want"
            sh_doc_fail=$((sh_doc_fail + 1))
        fi
    }
    sh_doctor_check home_writable "$(sh_dir_writable "$SH_HOME" && printf yes || printf no)" yes
    sh_doctor_check exec_writable "$(sh_dir_writable "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_runs "$(sh_exec_probe "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_on_path "$(case ":$PATH:" in *":$SH_EXEC_BIN:"*) printf yes ;; *) printf no ;; esac)" yes
    sh_doctor_check env_file "$([ -r "$SH_HOME/env.sh" ] && printf yes || printf no)" yes
    if [ "$SH_PTY" = no ]; then
        sh_doctor_check fakepty_built "$([ -f "$SH_HOME/shims/fakepty.so" ] && printf yes || printf no)" yes
    fi
    if [ "$SH_PASSWD" = no ]; then
        sh_doctor_check fakepwd_built "$([ -f "$SH_HOME/shims/fakepwd.so" ] && printf yes || printf no)" yes
    fi
    printf 'doctor_failures=%s\n' "$sh_doc_fail"
    unset -f sh_doctor_check
    return "$sh_doc_fail"
}
