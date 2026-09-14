#!/bin/bash
# End-to-end mode B test: ssh -> sandssh connect -> relay -> sandssh serve ->
# dropbear -i (chroot) -> session. Runs even in bindless cages by putting the
# relay on a unix socket (ws+unix://). Env overrides for other environments:
#   SANDBOX_RELAY_SOCK, SANDBOX_DROBEAR, SANDBOX_HOSTKEY, SANDBOX_CHROOT,
#   SANDBOX_CLIENT_KEY, SANDBOX_SSH
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_SOCK="${SANDBOX_RELAY_SOCK:-/tmp/sandssh-test-relay.sock}"
DROPBEAR="${SANDBOX_DROBEAR:-/workspace/build/droptest/bin/dropbear}"
HOSTKEY="${SANDBOX_HOSTKEY:-/etc/dropbear/hostkey}"
CHROOT="${SANDBOX_CHROOT:-/workspace/build/droptest}"
CLIENTKEY="${SANDBOX_CLIENT_KEY:-/workspace/build/clientkey}"
SSH_BIN="${SANDBOX_SSH:-ssh}"
SECRET="test-secret-$(date +%s)"
RELAY_PID=""; NODE_PID=""
rm -f "$RELAY_SOCK"
cleanup() {
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null || true
    rm -f "$RELAY_SOCK"
}
trap cleanup EXIT

python3 "$SRC/relay/sandssh-relay.py" --listen "$RELAY_SOCK" --key "$SECRET" --idle-timeout 60 &
RELAY_PID=$!
sleep 1

python3 "$SRC/bin/sandssh" serve --relay "ws+unix://$RELAY_SOCK" --name n1 \
    --auth "$SECRET" --dropbear "$DROPBEAR" --hostkey "$HOSTKEY" --chroot "$CHROOT" &
NODE_PID=$!
sleep 2

timeout 60 "$SSH_BIN" -i "$CLIENTKEY" \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no \
    -o PasswordAuthentication=no \
    -o ProxyCommand="python3 $SRC/bin/sandssh connect --relay ws+unix://$RELAY_SOCK --name n1 --auth $SECRET" \
    -o ConnectTimeout=30 \
    root@n1 "echo hello-over-relay && uname -s"
