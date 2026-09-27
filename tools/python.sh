#!/bin/sh
# python - a self-contained CPython through uv. uv is one static binary and it
# installs a python-build-standalone CPython into the sandhome root, so this
# never touches the system interpreter.
TC_python_DESC='CPython, installed by uv (uv is also left on PATH)'
TC_python_BINS=''

tc_python_probe() {
    if sh_have python3 && python3 --version >/dev/null 2>&1; then
        return 0
    fi
    if sh_have python && python --version >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

tc_python_install() {
    sh_pi_root=$(sh_toolchain_root python)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_pi_arch='x86_64-unknown-linux-gnu' ;;
        Linux:aarch64|Linux:arm64)  sh_pi_arch='aarch64-unknown-linux-gnu' ;;
        Linux:armv7l)               sh_pi_arch='armv7-unknown-linux-gnueabihf' ;;
        Darwin:x86_64)              sh_pi_arch='x86_64-apple-darwin' ;;
        Darwin:arm64)               sh_pi_arch='aarch64-apple-darwin' ;;
        *) sh_warn "no uv build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 400 home || return 1
    rm -rf "$sh_pi_root" 2>/dev/null
    mkdir -p "$sh_pi_root/bin" 2>/dev/null || return 1
    sh_pi_url="https://github.com/astral-sh/uv/releases/latest/download/uv-${sh_pi_arch}.tar.gz"
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install uv from $sh_pi_url and CPython 3.12 into $sh_pi_root"
        return 0
    fi
    if ! sh_fetch_unpack "$sh_pi_url" "$sh_pi_root/uv"; then
        sh_warn 'could not fetch or unpack uv'
        return 1
    fi
    # The archive's uv and uvx are moved to the module's own bin directory.
    for sh_pi_tool in uv uvx; do
        if [ -f "$sh_pi_root/uv/$sh_pi_tool" ]; then
            mv "$sh_pi_root/uv/$sh_pi_tool" "$sh_pi_root/bin/$sh_pi_tool" 2>/dev/null || true
        fi
    done
    rm -rf "$sh_pi_root/uv" 2>/dev/null

    # uv itself must run to install python, so the exec view is built now, before
    # the tool that needs it is used.
    sh_promote_toolchain python >/dev/null 2>&1
    sh_pi_view=$(sh_toolchain_view python)
    sh_pi_uv="$sh_pi_view/bin/uv"
    if [ ! -x "$sh_pi_uv" ]; then
        sh_warn "the promoted uv at $sh_pi_uv does not run"
        return 1
    fi
    mkdir -p "$sh_pi_root/python" "$SH_HOME/cache/uv" 2>/dev/null || true
    if ! UV_PYTHON_INSTALL_DIR="$sh_pi_root/python" UV_CACHE_DIR="$SH_HOME/cache/uv" \
         "$sh_pi_uv" python install 3.12 >/dev/null 2>&1; then
        sh_warn 'uv could not install CPython 3.12'
        return 1
    fi
    return 0
}

tc_python_env() {
    if tc_python_probe && ! sh_have uv; then
        # A working system python was adopted; leave PATH alone so the account's
        # own interpreter keeps winning.
        return 0
    fi
    sh_pe_root=$(sh_toolchain_root python)
    sh_promote_toolchain python >/dev/null 2>&1
    sh_pe_view=$(sh_toolchain_view python)
    sh_pe_bin=''
    for sh_pe_d in "$sh_pe_view"/python/*/bin "$sh_pe_root"/python/*/bin; do
        if [ -x "$sh_pe_d/python3" ] || [ -x "$sh_pe_d/python" ]; then
            sh_pe_bin=$sh_pe_d
            break
        fi
    done
    mkdir -p "$SH_HOME/cache/uv" 2>/dev/null || true
    sh_env_write_fragment python <<EOF
UV_PYTHON_INSTALL_DIR="$sh_pe_root/python"
UV_CACHE_DIR="\$SANDHOME_HOME/cache/uv"
UV_PYTHON_DOWNLOADS=never
PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_PYTHON_INSTALL_DIR UV_CACHE_DIR UV_PYTHON_DOWNLOADS PIP_DISABLE_PIP_VERSION_CHECK
case ":\$PATH:" in
  *":$sh_pe_view/bin:"*) ;;
  *) PATH="$sh_pe_view/bin:\$PATH" ;;
esac
export PATH
EOF
    if [ -n "$sh_pe_bin" ]; then
        cat >> "$(sh_env_fragment python)" <<EOF
case ":\$PATH:" in
  *":$sh_pe_bin:"*) ;;
  *) PATH="$sh_pe_bin:\$PATH" ;;
esac
export PATH
EOF
    fi
    return 0
}

tc_python_version() {
    if sh_have python3; then sh_first_line python3 --version 2>/dev/null; return 0; fi
    if sh_have python;  then sh_first_line python --version 2>/dev/null; return 0; fi
    printf ''
}
