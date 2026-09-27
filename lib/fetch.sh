#!/bin/sh
# fetch.sh - one download path, one checksum path, one unpack path. Sourced.
#
# ⚠ WHAT A RUN-TIME DIGEST PROVES IS TRANSPORT, NOT AUTHORSHIP. Where the
# expected digest comes from the same release as the bytes, whoever could replace
# one could replace the other. It is still the right check for a mirror that
# truncates a download; `SANDHOME_SHA256` adds the stronger pinned check back for
# a caller who holds the value.

# sh_fetch URL DEST -> 0 on a complete download. curl, then wget, then BSD fetch.
sh_fetch() {
    sh_f_url=$1
    sh_f_dest=$2
    if sh_have curl; then
        curl -fSL --retry 3 --retry-delay 2 -o "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    if sh_have wget; then
        wget -q -O "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    if sh_have fetch; then
        fetch -q -o "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    sh_warn 'no curl, wget or fetch is present, so nothing can be downloaded'
    return 1
}

# sh_redirect_target URL -> the URL a redirect lands on. This is how a `latest`
# release names its tag without parsing JSON anywhere.
sh_redirect_target() {
    if sh_have curl; then
        curl -fsSL -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null
        return 0
    fi
    if sh_have wget; then
        # wget --spider prints the chain; the last Location is the target.
        wget -q -S --spider "$1" 2>&1 | {
            sh_rt_last=''
            while read -r sh_rt_line; do
                case "$sh_rt_line" in
                    Location:*) sh_rt_last=$(sh_trim "${sh_rt_line#Location:}") ;;
                esac
            done
            printf '%s' "$sh_rt_last"
        }
        return 0
    fi
    printf ''
}

# sh_github_latest_tag OWNER/REPO -> the tag the `latest` release points at, or
# nothing. The redirect is what names the tag without parsing JSON anywhere.
# ⛔ `${url##*/tag/}` AND NOT `${url##*/}`: a tag that itself contains a slash
# (`release/1.2`) is returned whole, where the short form would truncate it.
sh_github_latest_tag() {
    sh_glt_url=$(sh_redirect_target "https://github.com/$1/releases/latest")
    case "$sh_glt_url" in
        */releases/tag/*) printf '%s' "${sh_glt_url##*/releases/tag/}" ;;
        */tag/*)          printf '%s' "${sh_glt_url##*/tag/}" ;;
        *)                printf '' ;;
    esac
}

# sh_sha256 FILE -> the lowercase hex digest, or nothing when no tool can take
# it. Five candidates, and every one is absent somewhere: sha256sum is coreutils,
# a BSD base has `sha256`, a minimal image may have only openssl, and python3
# arrives with the toolchain rather than before it.
sh_sha256() {
    if sh_have sha256sum; then sh_first_word sha256sum "$1"; return 0; fi
    if sh_have sha256;    then sha256 -q "$1" 2>/dev/null; return 0; fi
    if sh_have shasum;    then sh_first_word shasum -a 256 "$1"; return 0; fi
    if sh_have openssl;   then sh_first_word openssl dgst -sha256 -r "$1"; return 0; fi
    if sh_have python3; then
        python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
        return 0
    fi
    if sh_have node; then
        node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$1"
        return 0
    fi
    printf ''
}

# sh_fetch_verified URL DEST [EXPECTED_SHA256] -> fetch and, when a digest tool
# is present, prove the bytes. A missing digest tool is reported, not ignored:
# `SANDHOME_REQUIRE_DIGEST=1` turns that into a refusal.
sh_fetch_verified() {
    sh_fv_url=$1
    sh_fv_dest=$2
    sh_fv_expected=${3:-${SANDHOME_SHA256:-}}
    if ! sh_fetch "$sh_fv_url" "$sh_fv_dest"; then
        return 1
    fi
    sh_fv_actual=$(sh_sha256 "$sh_fv_dest")
    if [ -z "$sh_fv_actual" ]; then
        if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ]; then
            sh_fail "no sha256 tool is present, and SANDHOME_REQUIRE_DIGEST is set; refusing $sh_fv_url"
            return 1
        fi
        sh_warn "no sha256 tool is present, so $sh_fv_url could not be verified"
        return 0
    fi
    if [ -z "$sh_fv_expected" ]; then
        sh_step "sha256 $sh_fv_actual (no digest to compare against)"
        return 0
    fi
    if [ "$sh_fv_actual" != "$sh_fv_expected" ]; then
        sh_fail "$sh_fv_url does not match the expected sha256"
        return 1
    fi
    if [ -n "${SANDHOME_SHA256:-}" ]; then
        sh_step "sha256 matches the pinned value"
    else
        sh_step "sha256 matches the release digest"
    fi
    return 0
}

# sh_untar TARBALL DEST -> unpack .tar.gz, .tgz, .tar.xz, .txz, .tar.zst or .zip
# by reading the file, not the URL. A tar that cannot read the compression is
# reported rather than half-unpacking.
sh_untar() {
    sh_ut_file=$1
    sh_ut_dest=$2
    mkdir -p "$sh_ut_dest" 2>/dev/null || return 1
    case "$sh_ut_file" in
        *.zip)
            if sh_have unzip; then
                unzip -q -o "$sh_ut_file" -d "$sh_ut_dest"
                return $?
            fi
            if sh_have python3; then
                python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$sh_ut_file" "$sh_ut_dest"
                return $?
            fi
            sh_warn 'a .zip arrived and neither unzip nor python3 can open it'
            return 1
            ;;
    esac
    sh_ut_flags=''
    case "$sh_ut_file" in
        *.tar.gz|*.tgz) sh_ut_flags='-xzf' ;;
        *.tar.xz|*.txz) sh_ut_flags='-xJf' ;;
        *.tar.zst|*.tzst)
            if sh_have zstd; then
                sh_ut_flags='--zstd -xvf'
            else
                sh_warn 'a zstd tarball arrived and no zstd is present'
                return 1
            fi
            ;;
        *.tar.bz2|*.tbz|*.tbz2)
            if sh_have bzip2; then
                sh_ut_flags='-xjf'
            else
                sh_warn 'a bzip2 tarball arrived and no bzip2 is present'
                return 1
            fi
            ;;
        *.tar) sh_ut_flags='-xf' ;;
        *)
            sh_ut_flags='-xf'
            ;;
    esac
    # shellcheck disable=SC2086
    tar $sh_ut_flags "$sh_ut_file" -C "$sh_ut_dest"
    return $?
}

# sh_fetch_unpack URL DEST_DIR -> download to the home staging area, unpack, and
# answer the one top-level directory the archive made in MODULE_UNPACK_DIR. A
# tarball that makes several top-level entries is reported, because guessing
# which one is the toolchain is how a wrong tree gets moved into place.
sh_fetch_unpack() {
    sh_fu_url=$1
    sh_fu_dest=$2
    sh_fu_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_fu_stage" 2>/dev/null || return 1
    sh_fu_tmp="$sh_fu_stage/.fetch.$$"
    rm -rf "$sh_fu_tmp" 2>/dev/null
    mkdir -p "$sh_fu_tmp" 2>/dev/null || return 1
    sh_fu_file="$sh_fu_tmp/${sh_fu_url##*/}"
    if ! sh_fetch_verified "$sh_fu_url" "$sh_fu_file" "${SANDHOME_SHA256:-}"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    sh_fu_out="$sh_fu_tmp/out"
    if ! sh_untar "$sh_fu_file" "$sh_fu_out"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # Count the top-level entries without `ls | wc`.
    sh_fu_n=0
    sh_fu_one=''
    for sh_fu_e in "$sh_fu_out"/* "$sh_fu_out"/.[!.]*; do
        [ -e "$sh_fu_e" ] || continue
        sh_fu_n=$((sh_fu_n + 1))
        sh_fu_one=$sh_fu_e
    done
    if [ "$sh_fu_n" -eq 0 ]; then
        sh_warn "the archive from $sh_fu_url unpacked nothing"
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # The parent of DEST without dirname, which a minimal userland lacks.
    case "$sh_fu_dest" in
        */*) mkdir -p "${sh_fu_dest%/*}" 2>/dev/null || true ;;
    esac
    if [ "$sh_fu_n" -eq 1 ] && [ -d "$sh_fu_one" ]; then
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_one" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    else
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_out" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    fi
    rm -rf "$sh_fu_tmp" 2>/dev/null
    return 0
}
