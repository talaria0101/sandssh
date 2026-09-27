#!/bin/sh
# ripgrep - the search tool agents reach for first. A single musl binary.
TC_ripgrep_DESC='ripgrep (rg), the fast recursive search tool'
TC_ripgrep_BINS='bin/rg'

tc_ripgrep_probe() {
    sh_have rg && rg --version >/dev/null 2>&1
}

tc_ripgrep_install() {
    sh_rg_root=$(sh_toolchain_root ripgrep)
    sh_rg_tag=$(sh_github_latest_tag BurntSushi/ripgrep)
    case "$sh_rg_tag" in
        ''|*[!0-9.]*) sh_warn 'could not resolve the current ripgrep release tag'; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_rg_triple='x86_64-unknown-linux-musl' ;;
        Linux:aarch64|Linux:arm64) sh_rg_triple='aarch64-unknown-linux-gnu' ;;
        Darwin:x86_64)             sh_rg_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)              sh_rg_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no ripgrep release for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_rg_name="ripgrep-${sh_rg_tag}-${sh_rg_triple}"
    sh_rg_url="https://github.com/BurntSushi/ripgrep/releases/download/${sh_rg_tag}/${sh_rg_name}.tar.gz"
    sh_space_need 32 home || return 1
    rm -rf "$sh_rg_root" 2>/dev/null
    if ! sh_fetch_unpack "$sh_rg_url" "$sh_rg_root/stage"; then
        sh_warn 'could not fetch or unpack ripgrep'
        return 1
    fi
    mkdir -p "$sh_rg_root/bin" 2>/dev/null || return 1
    if [ -f "$sh_rg_root/stage/rg" ]; then
        mv "$sh_rg_root/stage/rg" "$sh_rg_root/bin/rg" 2>/dev/null || true
    fi
    rm -rf "$sh_rg_root/stage" 2>/dev/null
    [ -f "$sh_rg_root/bin/rg" ] || { sh_warn 'the ripgrep archive had no rg binary'; return 1; }
    return 0
}

tc_ripgrep_env() { return 0; }

tc_ripgrep_version() {
    sh_have rg && sh_first_line rg --version 2>/dev/null
}
