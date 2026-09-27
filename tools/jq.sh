#!/bin/sh
# jq - the JSON filter. A single static binary, which makes it the smallest
# complete test of the install -> promote -> exec path.
TC_jq_DESC='jq, the command-line JSON processor (single static binary)'
TC_jq_BINS='bin/jq'

tc_jq_probe() {
    sh_have jq && jq --version >/dev/null 2>&1
}

tc_jq_install() {
    sh_ji_root=$(sh_toolchain_root jq)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64) sh_ji_asset='jq-linux-amd64' ;;
        Linux:aarch64|Linux:arm64) sh_ji_asset='jq-linux-arm64' ;;
        Linux:i386|Linux:i686) sh_ji_asset='jq-linux-i386' ;;
        Darwin:*) sh_ji_asset='jq-macos-amd64' ;;
        *) sh_warn "no jq build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 16 home || return 1
    mkdir -p "$sh_ji_root/bin" 2>/dev/null || return 1
    sh_ji_url="https://github.com/jqlang/jq/releases/latest/download/$sh_ji_asset"
    if ! sh_fetch_verified "$sh_ji_url" "$sh_ji_root/bin/jq" "${SANDHOME_SHA256:-}"; then
        return 1
    fi
    chmod 0755 "$sh_ji_root/bin/jq" 2>/dev/null || true
    return 0
}

tc_jq_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_jq_version() {
    sh_have jq && jq --version 2>/dev/null
}
