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

log "done. next: export TS_AUTHKEY=<tailscale-auth-key> && $SRC/start.sh"
