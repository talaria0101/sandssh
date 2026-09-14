#!/bin/bash
# install.sh — provision the sandssh stack inside a sealed sandbox (agent- or human-run).
#
# What it does:
#   1. fetches tailscale (userspace networking) and tailcat (ssh-over-tailnet) binaries
#   2. builds the LD_PRELOAD shims from source (needs gcc; skipped if already built)
#   3. installs errandsh (userspace line discipline) and the scaffolding the
#      tailscaled chroot needs (etc/passwd, proc/self/exe, usr->. , dev/null)
#
# Everything is installed under $SANDSSH_HOME (default: $HOME). Idempotent:
# re-running never overwrites an existing node identity or ssh keys.
#
# Requirements: bash, curl or wget, (gcc only when shims are not prebuilt),
# python3 >= 3.7 (for errandsh), a tailscale auth key (for `start.sh up`).
set -euo pipefail

SANDSSH_HOME="${SANDSSH_HOME:-$HOME}"
SRC="$(cd "$(dirname "$0")" && pwd)"
TS_VERSION="${TS_VERSION:-1.102.4}"
TC_VERSION="${TC_VERSION:-0.6.0}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64) TARCH=amd64;; aarch64) TARCH=arm64;; *) echo "unsupported arch: $ARCH" >&2; exit 1;; esac

log() { printf '\e[1;36m[install]\e[0m %s\n' "$*"; }

fetch() { # fetch <url> <outfile>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi
}

mkdir -p "$SANDSSH_HOME/bin" "$SANDSSH_HOME/shims" "$SANDSSH_HOME/lib" \
         "$SANDSSH_HOME/ts-state" "$SANDSSH_HOME/.config/tailcat/keys" "$SANDSSH_HOME/tmp"

# --- 1. tailscale static binaries -------------------------------------------
# Source: https://pkgs.tailscale.com/stable/ (github carries source only).
# If your network blocks it, download the tgz yourself and point
# TS_TGZ=/path/to/tailscale_<ver>_<arch>.tgz at it, or drop prebuilt
# tailscaled+tailscale into $SANDSSH_HOME/bin and re-run.
if [ ! -x "$SANDSSH_HOME/bin/tailscaled" ]; then
  log "fetching tailscale $TS_VERSION ($TARCH)"
  if [ -n "${TS_TGZ:-}" ]; then
    cp "$TS_TGZ" "$SANDSSH_HOME/tmp/ts.tgz"
  else
    fetch "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${TARCH}.tgz" \
          "$SANDSSH_HOME/tmp/ts.tgz" || {
      echo "could not download tailscale." >&2
      echo "  - download https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${TARCH}.tgz" >&2
      echo "  - re-run with TS_TGZ=/path/to/that.tgz, or put tailscaled+tailscale" >&2
      echo "    in $SANDSSH_HOME/bin and re-run" >&2
      exit 1
    }
  fi
  tar --no-same-owner -xzf "$SANDSSH_HOME/tmp/ts.tgz" -C "$SANDSSH_HOME/tmp"
  cp "$SANDSSH_HOME/tmp/tailscale_${TS_VERSION}_${TARCH}/tailscaled" "$SANDSSH_HOME/bin/"
  cp "$SANDSSH_HOME/tmp/tailscale_${TS_VERSION}_${TARCH}/tailscale"    "$SANDSSH_HOME/bin/"
  rm -rf "$SANDSSH_HOME/tmp/tailscale_${TS_VERSION}_${TARCH}" "$SANDSSH_HOME/tmp/ts.tgz"
else
  log "tailscale binaries present"
fi

# --- 2. tailcat --------------------------------------------------------------
if [ ! -x "$SANDSSH_HOME/bin/tailcat" ]; then
  log "fetching tailcat $TC_VERSION ($TARCH)"
  fetch "https://github.com/tailscale/tailcat/releases/download/v${TC_VERSION}/tailcat_${TC_VERSION}_linux_${TARCH}.tar.gz" \
        "$SANDSSH_HOME/tmp/tc.tgz" ||
  fetch "https://github.com/tailscale/tailcat/releases/download/v${TC_VERSION}/tailcat_${TC_VERSION}_linux_${TARCH}.zip" \
        "$SANDSSH_HOME/tmp/tc.zip"
  if [ -f "$SANDSSH_HOME/tmp/tc.tgz" ]; then
    tar --no-same-owner -xzf "$SANDSSH_HOME/tmp/tc.tgz" -C "$SANDSSH_HOME/tmp" 2>/dev/null || true; find "$SANDSSH_HOME/tmp" -maxdepth 2 -name tailcat -type f -exec cp {} "$SANDSSH_HOME/bin/" \;
    rm -f "$SANDSSH_HOME/tmp/tc.tgz"
  else
    (cd "$SANDSSH_HOME/tmp" && python3 -c "import zipfile;zipfile.ZipFile('tc.zip').extractall()") \
      && find "$SANDSSH_HOME/tmp" -maxdepth 2 -name tailcat.exe -prune -o -maxdepth 2 -name tailcat -type f -print | head -1 | xargs -r -I{} cp {} "$SANDSSH_HOME/bin/"
    rm -f "$SANDSSH_HOME/tmp/tc.zip"
  fi
else
  log "tailcat binary present"
fi
[ -x "$SANDSSH_HOME/bin/tailcat" ] || { echo "tailcat not installed — grab it from https://github.com/tailscale/tailcat/releases and put it in $SANDSSH_HOME/bin/" >&2; exit 1; }

# --- 3. shims ----------------------------------------------------------------
if [ ! -f "$SANDSSH_HOME/shims/fakepwd.so" ]; then
  if command -v gcc >/dev/null 2>&1; then
    log "building shims"
    gcc -shared -fPIC -O2 -o "$SANDSSH_HOME/shims/fakepwd.so" "$SRC/shims/fakepwd.c"
    gcc -shared -fPIC -O2 -o "$SANDSSH_HOME/shims/fakepty.so" "$SRC/shims/fakepty.c"
  else
    log "no gcc; copying prebuilt shims (skip by building shims/*.c yourself)"
    cp "$SRC/shims/"*.so "$SANDSSH_HOME/shims/"
  fi
else
  log "shims present"
fi

# --- 3.5 sandssh CLI + relay -------------------------------------------------
install -m 755 "$SRC/bin/sandssh"        "$SANDSSH_HOME/bin/sandssh"
install -m 755 "$SRC/relay/sandssh-relay.py" "$SANDSSH_HOME/bin/sandssh-relay" 2>/dev/null || true

# --- 3.6 dropbear (mode B server: ssh over stdio, no bind, no inbound) -------
# dropbear -i speaks ssh on stdin/stdout, so it fits behind any outbound-only
# transport (the wss relay). Built static so it runs chrooted without libs.
if [ "${SANDSSH_SKIP_DROPBEAR:-0}" != "1" ] && [ ! -x "$SANDSSH_HOME/bin/dropbear" ]; then
  if command -v go >/dev/null 2>&1 && [ "${SANDSSH_TAILCAT_STDIO:-0}" = "1" ]; then
    log "tailcat serve-stdio requested; see docs/ -- falling back to dropbear here"
  fi
  DB_SRC="${DROPBEAR_SRC:-$SANDSSH_HOME/src/dropbear}"
  if [ ! -d "$DB_SRC" ]; then
    log "fetching dropbear (github)"
    mkdir -p "$(dirname "$DB_SRC")"
    git clone --depth 1 https://github.com/mkj/dropbear "$DB_SRC" || {
      echo "could not clone dropbear; set DROPBEAR_SRC to a populated tree" >&2; }
  fi
  if [ -d "$DB_SRC" ]; then
    CC_BIN="${DROPBEAR_CC:-}"
    [ -z "$CC_BIN" ] && for c in /opt/bootlin/x86-64-musl/bin/x86_64-buildroot-linux-musl-cc \
                              /opt/bootlin/aarch64-musl/bin/aarch64-buildroot-linux-musl-cc \
                              cc; do
      [ -x "$c" ] && CC_BIN="$c" && break
    done
    log "building dropbear (static) with $CC_BIN"
    ( cd "$DB_SRC" && git apply "$SRC/patches/dropbear-inetd-pipe-tolerance.patch" 2>/dev/null || true
      git apply "$SRC/patches/dropbear-setgroups-tolerance.patch" 2>/dev/null || true
      case "$CC_BIN" in *aarch64*) HOSTTRIPLE="--host=aarch64-linux-musl";; *musl*) HOSTTRIPLE="--host=x86_64-linux-musl";; *) HOSTTRIPLE="";; esac
      ./configure CC="$CC_BIN" $HOSTTRIPLE --disable-zlib --disable-lastlog \
        --disable-utmp --disable-wtmp --disable-utmpx --disable-wtmpx \
        >/dev/null 2>&1 && make -j4 STATIC=1 LDFLAGS="-static" dropbear dropbearkey \
        >/dev/null 2>&1 && cp dropbear dropbearkey "$SANDSSH_HOME/bin/" ) \
      && log "dropbear built" || log "dropbear build failed; mode B needs it (or set SANDSSH_DROBEAR_BIN)"
  fi
fi
[ -x "$SANDSSH_HOME/bin/dropbear" ] && [ ! -f "$SANDSSH_HOME/etc/dropbear/hostkey" ] && {
  mkdir -p "$SANDSSH_HOME/etc/dropbear"
  "$SANDSSH_HOME/bin/dropbearkey" -t ed25519 -f "$SANDSSH_HOME/etc/dropbear/hostkey" >/dev/null 2>&1 \
    && log "generated dropbear hostkey"
}

# --- 3.7 chroot scaffold for dropbear (passwd/shells/urandom + session shell) -
if [ -x "$SANDSSH_HOME/bin/dropbear" ]; then
  log "building dropbear chroot overlay at $SANDSSH_HOME"
  mkdir -p "$SANDSSH_HOME/etc/dropbear" "$SANDSSH_HOME/dev" "$SANDSSH_HOME/root/.ssh"
  printf 'root:x:0:0:root:/root:/bin/errandsh\n' > "$SANDSSH_HOME/etc/passwd"
  printf 'root:x:0:\n' > "$SANDSSH_HOME/etc/group"
  printf '/bin/errandsh\n/bin/bash\n/bin/sh\n' > "$SANDSSH_HOME/etc/shells"
  [ -e "$SANDSSH_HOME/dev/null" ] || : > "$SANDSSH_HOME/dev/null"
  [ -e "$SANDSSH_HOME/dev/urandom" ] || head -c 32 /dev/urandom > "$SANDSSH_HOME/dev/urandom" 2>/dev/null || true
  ln -sfn . "$SANDSSH_HOME/usr"
  # session shell: python3 + errandsh + their libs, so the REPL works chrooted
  PY3="$(command -v python3 || true)"
  if [ -n "$PY3" ] && [ ! -x "$SANDSSH_HOME/bin/python3" ]; then
    log "installing python3 + errandsh into the chroot"
    cp "$PY3" "$SANDSSH_HOME/bin/python3"
    for lib in $(ldd "$PY3" | awk '{print $3}' | grep '^/'); do
      mkdir -p "$SANDSSH_HOME$(dirname "$lib")"; cp -n "$lib" "$SANDSSH_HOME$lib" 2>/dev/null || true
    done
    PYSTD="$(python3 -c 'import sys; print(sys.prefix)')/lib/python3.*"
    for d in $PYSTD; do mkdir -p "$SANDSSH_HOME/usr/lib"; cp -r "$d" "$SANDSSH_HOME/usr/lib/" 2>/dev/null || true; done
    sed '1s|.*|#!/bin/python3|' "$SRC/shell/errandsh" > "$SANDSSH_HOME/bin/errandsh"
    chmod 755 "$SANDSSH_HOME/bin/errandsh"
    # bash for the REPL's long-lived job (best effort)
    BASH_BIN="$(command -v bash || true)"
    if [ -n "$BASH_BIN" ]; then
      cp "$BASH_BIN" "$SANDSSH_HOME/bin/bash.real"
      for lib in $(ldd "$BASH_BIN" | awk '{print $3}' | grep '^/'); do
        mkdir -p "$SANDSSH_HOME$(dirname "$lib")"; cp -n "$lib" "$SANDSSH_HOME$lib" 2>/dev/null || true
      done
      ln -sf bash.real "$SANDSSH_HOME/bin/bash"
    fi
  fi
  # authorized keys for dropbear (mode B)
  if [ -n "${SANDSSH_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$SANDSSH_AUTHORIZED_KEYS" > "$SANDSSH_HOME/root/.ssh/authorized_keys"
    log "installed authorized_keys from SANDSSH_AUTHORIZED_KEYS"
  fi
fi

# --- 4. errandsh + wrappers ---------------------------------------------------
install -m 755 "$SRC/shell/errandsh" "$SANDSSH_HOME/bin/errandsh"
install -m 755 "$SRC/bin/ssh"        "$SANDSSH_HOME/bin/ssh" 2>/dev/null || true
install -m 755 "$SRC/bin/getent"     "$SANDSSH_HOME/bin/getent"

# --- 5. chroot scaffold for tailscaled ---------------------------------------
# tailscaled is a static Go binary, but its SSH server reads /etc/passwd and
# /proc/self/exe. The sandbox /etc and /proc are sealed, so run it chrooted
# at $SANDSSH_HOME with a tiny overlay we control.
log "building chroot overlay at $SANDSSH_HOME"
mkdir -p "$SANDSSH_HOME/etc" "$SANDSSH_HOME/proc/self" "$SANDSSH_HOME/dev"
cp -n "$SRC/overlay/etc/passwd" "$SRC/overlay/etc/group" \
      "$SRC/overlay/etc/nsswitch.conf" "$SRC/overlay/etc/resolv.conf" "$SANDSSH_HOME/etc/" 2>/dev/null || true
[ -e "$SANDSSH_HOME/dev/null" ] || : > "$SANDSSH_HOME/dev/null"
ln -sfn . "$SANDSSH_HOME/usr"
ln -sfn /bin/tailscaled "$SANDSSH_HOME/proc/self/exe"
mkdir -p "$SANDSSH_HOME/bin.d" 2>/dev/null || true

# --- 6. ssh keys (optional, for inbound tailscale-ssh exec) -------------------
mkdir -p "$SANDSSH_HOME/.ssh"
if [ ! -f "$SANDSSH_HOME/.ssh/id_ed25519" ]; then
  if /usr/bin/ssh-keygen -t ed25519 -N "" -f "$SANDSSH_HOME/.ssh/id_ed25519" -C sandssh >/dev/null 2>&1; then
    log "generated ssh keypair .ssh/id_ed25519"
  else
    LD_PRELOAD="$SANDSSH_HOME/shims/fakepwd.so" /usr/bin/ssh-keygen -t ed25519 -N "" \
      -f "$SANDSSH_HOME/.ssh/id_ed25519" -C sandssh >/dev/null 2>&1 && log "generated ssh keypair (with fakepwd)" || log "ssh-keygen unavailable; skip"
  fi
fi
touch "$SANDSSH_HOME/.ssh/authorized_keys" 2>/dev/null || true
chmod 700 "$SANDSSH_HOME/.ssh" 2>/dev/null || true

log "done. next:
  mode A (tailscale):  export TS_AUTHKEY=<key> && $SRC/start.sh
  mode B (relay):      $SRC/start.sh serve --relay wss://your-relay --name N
  mode C (github-only): $SRC/start.sh gh
  probe:               $SANDSSH_HOME/bin/sandssh probe" 
