#!/bin/sh
# fd - the friendlier find. A single musl binary from GitHub releases.
TC_fd_DESC='fd, a fast and user-friendly find replacement'
TC_fd_BINS='bin/fd'

tc_fd_probe() {
    sh_have fd && fd --version >/dev/null 2>&1
}

tc_fd_install() {
    sh_fd_root=$(sh_toolchain_root fd)
    sh_fd_tag=$(sh_github_latest_tag sharkdp/fd)
    case "$sh_fd_tag" in
        v*) ;;
        *) sh_warn 'could not resolve the current fd release tag'; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_fd_triple='x86_64-unknown-linux-musl' ;;
        Linux:aarch64|Linux:arm64) sh_fd_triple='aarch64-unknown-linux-musl' ;;
        Darwin:x86_64)             sh_fd_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)              sh_fd_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no fd release for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_fd_name="fd-${sh_fd_tag}-${sh_fd_triple}"
    sh_fd_url="https://github.com/sharkdp/fd/releases/download/${sh_fd_tag}/${sh_fd_name}.tar.gz"
    sh_space_need 32 home || return 1
    rm -rf "$sh_fd_root" 2>/dev/null
    if ! sh_fetch_unpack "$sh_fd_url" "$sh_fd_root/stage"; then
        sh_warn 'could not fetch or unpack fd'
        return 1
    fi
    mkdir -p "$sh_fd_root/bin" 2>/dev/null || return 1
    if [ -f "$sh_fd_root/stage/fd" ]; then
        mv "$sh_fd_root/stage/fd" "$sh_fd_root/bin/fd" 2>/dev/null || true
    fi
    rm -rf "$sh_fd_root/stage" 2>/dev/null
    [ -f "$sh_fd_root/bin/fd" ] || { sh_warn 'the fd archive had no fd binary'; return 1; }
    return 0
}

tc_fd_env() { return 0; }

tc_fd_version() {
    sh_have fd && sh_first_line fd --version 2>/dev/null
}
