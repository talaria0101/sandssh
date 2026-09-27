#!/bin/sh
# rust - the Rust toolchain through rustup, into the sandhome root.
TC_rust_DESC='Rust via rustup (rustc, cargo, rustfmt, clippy; minimal profile)'
TC_rust_BINS=''

tc_rust_probe() {
    sh_have rustc && rustc --version >/dev/null 2>&1
}

tc_rust_install() {
    sh_ri_root=$(sh_toolchain_root rust)
    sh_ri_rustup="$sh_ri_root/rustup"
    sh_ri_cargo="$sh_ri_root/cargo"

    # ⭐ AN EXISTING WORKING RUSTUP IS THE FASTEST INSTALL. If the machine already
    # has rustup, it is asked to place the toolchain under this root rather than a
    # second copy of the installer being fetched.
    if sh_have rustup; then
        if RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
           rustup toolchain install stable --profile minimal \
           -c rustfmt -c clippy --no-self-update >/dev/null 2>&1; then
            sh_step 'installed the stable toolchain with the rustup already here'
            return 0
        fi
        sh_warn 'the rustup on PATH could not install into the sandhome root; falling back to rustup-init'
    fi

    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='x86_64-unknown-linux-musl'
            else
                sh_ri_triple='x86_64-unknown-linux-gnu'
            fi ;;
        Linux:aarch64|Linux:arm64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='aarch64-unknown-linux-musl'
            else
                sh_ri_triple='aarch64-unknown-linux-gnu'
            fi ;;
        Linux:i386|Linux:i686) sh_ri_triple='i686-unknown-linux-gnu' ;;
        Darwin:x86_64)         sh_ri_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)          sh_ri_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no rustup-init for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 900 home || return 1
    mkdir -p "$sh_ri_rustup" "$sh_ri_cargo" 2>/dev/null || return 1
    sh_ri_url="https://static.rust-lang.org/rustup/dist/${sh_ri_triple}/rustup-init"
    sh_ri_init="$SH_HOME_TMP/rustup-init.$$"
    if ! sh_fetch_verified "$sh_ri_url" "$sh_ri_init" "${SANDHOME_SHA256:-}"; then
        return 1
    fi
    chmod 0755 "$sh_ri_init" 2>/dev/null || true
    if ! RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
         "$sh_ri_init" -y --no-modify-path --profile minimal \
         --default-toolchain stable -c rustfmt -c clippy >/dev/null 2>&1; then
        sh_warn 'rustup-init could not install the toolchain'
        rm -f "$sh_ri_init" 2>/dev/null
        return 1
    fi
    rm -f "$sh_ri_init" 2>/dev/null
    return 0
}

# ⛔ THE TOOLCHAIN BIN DIRECTORY IS ON PATH DIRECTLY, NOT BY BASENAME. rustc
# resolves its sysroot from the directory it is run from: a copy of the binary at
# the exec view's root, without the mirrored `lib/` beside it, reports the wrong
# sysroot and cannot find its own standard library. The mirrored tree keeps the
# executable at the same depth, so the sysroot resolves.
tc_rust_env() {
    if tc_rust_probe; then
        # An adopted rustc already runs; rewriting PATH to a tree that was never
        # installed would break it.
        return 0
    fi
    sh_re_root=$(sh_toolchain_root rust)
    sh_promote_toolchain rust >/dev/null 2>&1
    sh_re_view=$(sh_toolchain_view rust)
    sh_re_bin=''
    for sh_re_d in "$sh_re_view"/rustup/toolchains/*/bin "$sh_re_root"/rustup/toolchains/*/bin; do
        if [ -x "$sh_re_d/rustc" ]; then
            sh_re_bin=$sh_re_d
            break
        fi
    done
    if [ -z "$sh_re_bin" ]; then
        sh_warn 'no rustc was found under the rustup root after install'
        return 1
    fi
    sh_env_write_fragment rust <<EOF
RUSTUP_HOME="$sh_re_root/rustup"
CARGO_HOME="$sh_re_root/cargo"
export RUSTUP_HOME CARGO_HOME
case ":\$PATH:" in
  *":$sh_re_bin:"*) ;;
  *) PATH="$sh_re_bin:\$PATH" ;;
esac
export PATH
EOF
    return $?
}

tc_rust_version() {
    sh_have rustc && sh_first_line rustc --version 2>/dev/null
}
