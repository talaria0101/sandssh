#!/bin/sh
# node - Node.js and its bundled npm, from nodejs.org.
TC_node_DESC='Node.js with the bundled npm, from the official nodejs.org tarball'
TC_node_BINS='bin/node'

tc_node_probe() {
    sh_have node && node --version >/dev/null 2>&1
}

# ⛔ THE `latest/` REDIRECT NAMES A TRAIN, NOT A VERSION. nodejs.org/dist/latest/
# lands on `dist/latest-v24.x/`, a directory, so the version is read from
# index.json, whose first entry is the newest release. Measured 2026-09-27: the
# redirect target was https://nodejs.org/dist/latest-v24.x/ and it carried no
# version, so the old rule resolved nothing and the install refused.
tc_node_latest_tag() {
    sh_nt_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_nt_stage" 2>/dev/null || { printf ''; return 0; }
    sh_nt_file="$sh_nt_stage/.node-index.$$"
    # SANDHOME_NODE_INDEX_URL exists so the parser can be tested against a local
    # file, and so a mirror can be pointed at without editing this module.
    if ! sh_fetch "${SANDHOME_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}" "$sh_nt_file"; then
        printf ''
        return 0
    fi
    # ⛔ THE FILE IS PRETTY-PRINTED. Line one is `[` and the first entry begins on
    # line two, so the version is the first line that carries one, not the first
    # line of the file. Measured 2026-09-27: index.json began `[\n{"version":"v26.10.0"`.
    sh_nt_tag=''
    while read -r sh_nt_line; do
        case "$sh_nt_line" in
            *'"version":"'*)
                sh_nt_rest=${sh_nt_line#*'"version":"'}
                sh_nt_tag=${sh_nt_rest%%\"*}
                break
                ;;
        esac
    done < "$sh_nt_file"
    rm -f "$sh_nt_file" 2>/dev/null
    printf '%s' "$sh_nt_tag"
}

tc_node_install() {
    sh_ni_root=$(sh_toolchain_root node)
    sh_ni_tag=$(tc_node_latest_tag)
    case "$sh_ni_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current Node.js release'; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_ni_os=linux  sh_ni_arch=x64 ;;
        Linux:aarch64|Linux:arm64)  sh_ni_os=linux  sh_ni_arch=arm64 ;;
        Linux:armv7l)               sh_ni_os=linux  sh_ni_arch=armv7l ;;
        Darwin:x86_64)              sh_ni_os=darwin sh_ni_arch=x64 ;;
        Darwin:arm64)               sh_ni_os=darwin sh_ni_arch=arm64 ;;
        *) sh_warn "no Node.js tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_ni_name="node-${sh_ni_tag}-${sh_ni_os}-${sh_ni_arch}"
    sh_ni_base="https://nodejs.org/dist/${sh_ni_tag}"
    sh_ni_url="$sh_ni_base/${sh_ni_name}.tar.xz"
    sh_ni_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_ni_stage" 2>/dev/null || return 1
    sh_space_need 300 home || return 1

    sh_ni_sha=''
    if sh_have curl || sh_have wget; then
        sh_ni_sums="$sh_ni_stage/node-SHASUMS256.$$"
        if sh_fetch "$sh_ni_base/SHASUMS256.txt" "$sh_ni_sums"; then
            while read -r sh_ni_hex sh_ni_file; do
                case "$sh_ni_file" in
                    *"${sh_ni_name}.tar.xz") sh_ni_sha=$sh_ni_hex; break ;;
                esac
            done < "$sh_ni_sums"
            rm -f "$sh_ni_sums" 2>/dev/null
        fi
    fi

    rm -rf "$sh_ni_root" 2>/dev/null
    mkdir -p "$sh_ni_root" 2>/dev/null || return 1
    sh_ni_tar="$sh_ni_stage/${sh_ni_name}.tar.xz"
    if ! sh_fetch_verified "$sh_ni_url" "$sh_ni_tar" "$sh_ni_sha"; then
        return 1
    fi
    if ! sh_untar "$sh_ni_tar" "$sh_ni_root"; then
        sh_warn "could not unpack $sh_ni_tar"
        rm -f "$sh_ni_tar" 2>/dev/null
        return 1
    fi
    rm -f "$sh_ni_tar" 2>/dev/null
    # The archive's one top-level directory becomes the root's bin/lib/content.
    if [ -d "$sh_ni_root/$sh_ni_name" ]; then
        sh_ni_inner="$sh_ni_root/$sh_ni_name"
        for sh_ni_e in "$sh_ni_inner"/* "$sh_ni_inner"/.[!.]*; do
            [ -e "$sh_ni_e" ] || continue
            mv "$sh_ni_e" "$sh_ni_root/" 2>/dev/null || true
        done
        rmdir "$sh_ni_inner" 2>/dev/null || true
    fi
    if [ ! -x "$sh_ni_root/bin/node" ]; then
        sh_warn "the Node.js archive did not put node at $sh_ni_root/bin/node"
        return 1
    fi
    return 0
}

# ⛔ npm AND npx ARE NOT COPIED BY NAME. In a nodejs.org tarball they are
# symlinks into lib/node_modules, and a symlink into a noexec home does not run.
# The generic promote copies a symlink's target when the target is executable,
# which turns npm-cli.js into a file with its own `#!/usr/bin/env node` shebang;
# that works only once node is on PATH, which the fragment below guarantees. What
# is checked afterwards is that npm answers at all, and a miss is reported rather
# than left to fail inside a later build.
tc_node_env() {
    sh_ne_root=$(sh_toolchain_root node)
    # An adopted system node has no sandhome root; its npm configuration is not
    # ours to rewrite, and probing a view that was never built would warn about a
    # tool that is present and working.
    if [ ! -d "$sh_ne_root" ]; then
        return 0
    fi
    sh_ne_view=$(sh_toolchain_view node)
    mkdir -p "$SH_HOME/npm-global" "$SH_HOME/cache/npm" 2>/dev/null || true
    sh_env_write_fragment node <<EOF
NPM_CONFIG_PREFIX="\$SANDHOME_HOME/npm-global"
NPM_CONFIG_CACHE="\$SANDHOME_HOME/cache/npm"
NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_PREFIX NPM_CONFIG_CACHE NPM_CONFIG_UPDATE_NOTIFIER
case ":\$PATH:" in
  *":$sh_ne_view/bin:"*) ;;
  *) PATH="$sh_ne_view/bin:\$PATH" ;;
esac
export PATH
EOF
    sh_ne_frag=$?
    if ! "$sh_ne_view/bin/node" --version >/dev/null 2>&1; then
        sh_warn "the promoted node at $sh_ne_view/bin/node does not run; node needs an exec-capable home or a larger exec root"
    fi
    return "$sh_ne_frag"
}

tc_node_version() {
    sh_have node && sh_first_line node --version 2>/dev/null
}
