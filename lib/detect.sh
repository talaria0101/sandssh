#!/bin/sh
# detect.sh - what machine is this, and what may it do. Sourced by bootstrap.sh
# and by bin/sandhome. Every answer is read off the machine rather than assumed,
# and the answers are exported with a SH_ prefix.

# ⭐ THE KERNEL DECIDES THE FAMILY, then the family decides what to look for. A
# bare search for `pkg` on PATH is wrong in both directions: pkgsrc puts one on
# some Linux machines, and a FreeBSD jail can carry a Linux emulation layer.
SH_PROVIDERS='apk apt dnf emerge pacman pkg pkg_add pkgin tdnf xbps yum zypper'

sh_detect_provider() {
    case "$(uname -s)" in
        FreeBSD|DragonFly)
            if sh_have pkg; then printf 'pkg'; return 0; fi
            printf ''
            return 0
            ;;
        NetBSD)
            # pkgin first and pkg_add second: both are real and one installs the
            # other, and a stock NetBSD base carries pkg_add and not pkgin.
            if sh_have pkgin; then printf 'pkgin'; return 0; fi
            if sh_have pkg_add; then printf 'pkg_add'; return 0; fi
            printf ''
            return 0
            ;;
        OpenBSD)
            if sh_have pkg_add; then printf 'pkg_add'; return 0; fi
            printf ''
            return 0
            ;;
    esac
    # Not alphabetical. A distribution can carry more than one; Fedora keeps a
    # `yum` that forwards to `dnf`, so the native one is tried first.
    if sh_have apk;          then printf 'apk';     return 0; fi
    if sh_have pacman;       then printf 'pacman';  return 0; fi
    if sh_have apt-get;      then printf 'apt';     return 0; fi
    if sh_have zypper;       then printf 'zypper';  return 0; fi
    if sh_have dnf;          then printf 'dnf';     return 0; fi
    if sh_have tdnf;         then printf 'tdnf';    return 0; fi
    if sh_have yum;          then printf 'yum';     return 0; fi
    if sh_have xbps-install; then printf 'xbps';    return 0; fi
    if sh_have emerge;       then printf 'emerge';  return 0; fi
    printf ''
}

# OpenBSD, NetBSD and MidnightBSD have no /etc/os-release; the kernel fallback
# is what keeps their `os:` rows from being dead.
sh_detect_os_id() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [ -n "${ID:-}" ]; then
            printf '%s' "$ID"
            return 0
        fi
    fi
    case "$(uname -s)" in
        FreeBSD)   printf 'freebsd' ;;
        NetBSD)    printf 'netbsd' ;;
        OpenBSD)   printf 'openbsd' ;;
        DragonFly) printf 'dragonfly' ;;
        Darwin)    printf 'darwin' ;;
        *)         printf 'unknown' ;;
    esac
}

# ⚠ `ldd --version` writes to stdout on glibc, to stderr on musl, and exits 1 on
# musl while doing it. Looking for the loader is the answer that does not depend
# on which one is there. The multiarch glob is not optional: Debian and Ubuntu
# keep libc at /lib/x86_64-linux-gnu/libc.so.6 and nothing at the four obvious
# paths.
sh_detect_libc() {
    case "$(uname -s)" in
        Linux) ;;
        *) printf 'libc'; return 0 ;;
    esac
    for sh_dl_candidate in /lib/ld-musl-* /usr/lib/ld-musl-*; do
        if [ -e "$sh_dl_candidate" ]; then
            printf 'musl'
            return 0
        fi
    done
    for sh_dl_candidate in \
        /lib/libc.so.6 /lib64/libc.so.6 /usr/lib/libc.so.6 /usr/lib64/libc.so.6 \
        /lib/*-linux-gnu/libc.so.6 /usr/lib/*-linux-gnu/libc.so.6; do
        if [ -e "$sh_dl_candidate" ]; then
            printf 'glibc'
            return 0
        fi
    done
    printf 'unknown'
}

sh_detect_wsl() {
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSLENV:-}" ]; then
        printf 'yes'
        return 0
    fi
    if [ -r /proc/sys/kernel/osrelease ]; then
        sh_dw_release=''
        read -r sh_dw_release < /proc/sys/kernel/osrelease || sh_dw_release=''
        case "$sh_dw_release" in
            *[Mm]icrosoft*) printf 'yes'; return 0 ;;
        esac
    fi
    printf 'no'
}

# ⭐ THE PRIVILEGE ANSWER IS THREE-VALUED, and collapsing it to a boolean is what
# makes a bootstrap hang. `sudo` without -n waits on a terminal an unattended run
# does not have, so a password-requiring sudo is reported as no privilege rather
# than tried.
sh_detect_privilege() {
    if [ "$(id -u)" = 0 ]; then
        printf 'root'
        return 0
    fi
    if sh_have sudo && sudo -n true 2>/dev/null; then
        printf 'sudo'
        return 0
    fi
    printf 'none'
}

# sh_as_root COMMAND... -> run as the detected privilege, or fail.
sh_as_root() {
    case "${SH_PRIVILEGE:-none}" in
        root) "$@" ;;
        sudo) sudo -n "$@" ;;
        *)    return 1 ;;
    esac
}

# sh_detect_pty -> yes when a kernel pty can be opened. A cage without /dev/ptmx
# and without devpts gets no, and that is exactly the case errandsh and fakepty
# exist for.
sh_detect_pty() {
    if [ -e /dev/ptmx ]; then
        printf 'yes'
        return 0
    fi
    printf 'no'
}

# sh_detect_passwd -> yes when a passwd database answers. `getent` is absent on
# some cages; reading /etc/passwd is the fallback. A cage with neither gets no,
# which is the case fakepwd exists for.
sh_detect_passwd() {
    if [ -r /etc/passwd ]; then
        printf 'yes'
        return 0
    fi
    if sh_have getent; then
        if getent passwd "$(id -un 2>/dev/null)" >/dev/null 2>&1; then
            printf 'yes'
            return 0
        fi
    fi
    printf 'no'
}

# sh_detect_bind -> yes when a socket can be bound at all. A seccomp profile can
# deny bind(2) while allowing connect(2), which is the whole reason podssh dials
# out and never listens.
sh_detect_bind() {
    if sh_have python3; then
        if python3 -c 'import socket,sys
s=socket.socket()
try:
    s.bind(("127.0.0.1",0))
except OSError:
    sys.exit(1)
finally:
    s.close()
' >/dev/null 2>&1; then
            printf 'yes'
            return 0
        fi
        printf 'no'
        return 0
    fi
    printf 'unknown'
}

# sh_detect_all -> read every answer and export it. One place, so a script added
# later reads the same answer as every other.
sh_detect_all() {
    SH_OS_ID=$(sh_detect_os_id)
    SH_KERNEL=$(uname -s 2>/dev/null) || SH_KERNEL=unknown
    SH_ARCH=$(uname -m 2>/dev/null) || SH_ARCH=unknown
    SH_LIBC=$(sh_detect_libc)
    SH_WSL=$(sh_detect_wsl)
    SH_PRIVILEGE=$(sh_detect_privilege)
    SH_PROVIDER=$(sh_detect_provider)
    SH_PTY=$(sh_detect_pty)
    SH_PASSWD=$(sh_detect_passwd)
    export SH_OS_ID SH_KERNEL SH_ARCH SH_LIBC SH_WSL SH_PRIVILEGE SH_PROVIDER
    export SH_PTY SH_PASSWD
}

# sh_arch_go -> the GOARCH spelling of this machine.
sh_arch_go() {
    case "${SH_ARCH:-unknown}" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv6l) printf 'armv6l' ;;
        i386|i686)     printf '386' ;;
        *)             printf '%s' "${SH_ARCH:-unknown}" ;;
    esac
}

# sh_arch_node -> the nodejs.org spelling.
sh_arch_node() {
    case "${SH_ARCH:-unknown}" in
        x86_64|amd64)  printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l)        printf 'armv7l' ;;
        *)             printf '%s' "${SH_ARCH:-unknown}" ;;
    esac
}

# sh_arch_rust -> the rustup target-triple spelling for this libc and kernel.
sh_arch_rust() {
    case "${SH_KERNEL:-unknown}" in
        Linux)
            case "${SH_LIBC:-unknown}" in
                musl) printf '%s-unknown-linux-musl' "${SH_ARCH:-unknown}" ;;
                *)    printf '%s-unknown-linux-gnu' "${SH_ARCH:-unknown}" ;;
            esac
            ;;
        Darwin) printf '%s-apple-darwin' "${SH_ARCH:-unknown}" ;;
        *)      printf '%s-unknown-unknown' "${SH_ARCH:-unknown}" ;;
    esac
}
