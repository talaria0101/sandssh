#!/bin/bash
# start.sh — bring the sandssh stack up (run after install.sh).
#
#   TS_AUTHKEY=<key> ./start.sh          join tailnet + start tailcat ssh
#   ./start.sh status                     tailscale status
#   ./start.sh addr                       print node ipv4
#
# Components:
#   tailscaled (chrooted at $SANDSSH_HOME, userspace-networking, state in
#   ./ts-state so node identity survives restarts) and tailcat serve
#   no-auth-ssh (interactive-ish root shell over the tailnet, no keys:
#   transport identity = tailnet membership).
set -euo pipefail

SANDSSH_HOME="${SANDSSH_HOME:-$HOME}"
NODE_NAME="${SANDSSH_NODE_NAME:-sandssh-node}"
TS_SOCKET="$SANDSSH_HOME/ts-state/tailscaled.sock"
TS="$SANDSSH_HOME/bin/tailscale --socket=$TS_SOCKET"

log() { printf '\e[1;36m[start]\e[0m %s\n' "$*"; }

case "${1:-up}" in
  status) exec $TS status ;;
  addr)   $TS ip -4 | head -1 ;;
esac

pgrep -x tailscaled >/dev/null 2>&1 || {
  log "starting tailscaled (userspace networking, chrooted at $SANDSSH_HOME)"
  # chroot: sandbox /etc and /proc are sealed; tailscaled needs both.
  # USER/LOGNAME/HOME: its ssh server resolves the login user dynamically.
  nohup chroot "$SANDSSH_HOME" /bin/tailscaled \
    --tun=userspace-networking \
    --statedir=/ts-state --socket=/ts-state/tailscaled.sock \
    >> "$SANDSSH_HOME/ts-state/tailscaled.log" 2>&1 &
  sleep 3
}

$TS status >/dev/null 2>&1 || true
if ! $TS status 2>/dev/null | grep -q .; then
  log "waiting for tailscaled socket"; sleep 4
fi

if [ -n "${TS_AUTHKEY:-}" ]; then
  log "joining tailnet as $NODE_NAME (ssh enabled)"
  # --ssh: inbound tailscale-ssh (exec; interactive pty is impossible in a
  # cage without /dev/ptmx). STATE persists the node key: one auth per disk.
  $TS up --authkey="$TS_AUTHKEY" --hostname="$NODE_NAME" --ssh \
      || $TS up --authkey="$TS_AUTHKEY" --hostname="$NODE_NAME"
else
  log "TS_AUTHKEY not set; assuming already joined"
fi

pgrep -x tailcat >/dev/null 2>&1 || {
  log "starting tailcat serve no-auth-ssh"
  env USER=root LOGNAME=root HOME="$SANDSSH_HOME" \
      SHELL="$SANDSSH_HOME/bin/errandsh" \
      nohup "$SANDSSH_HOME/bin/tailcat" serve no-auth-ssh \
      >> "$SANDSSH_HOME/ts-state/tailcat.log" 2>&1 &
  sleep 2
}

IP="$($TS ip -4 2>/dev/null | head -1 || echo '?')"
TC_ADDR="$(grep -oE 'tcp[A-Za-z0-9_-]{40,}' "$SANDSSH_HOME/ts-state/tailcat.log" 2>/dev/null | tail -1 || true)"

log "node up:    ssh root@$IP \"cmd\"            (tailscale-ssh, exec only)"
log "interactive tailcat ssh root@$TC_ADDR   (from any machine on the tailnet)"
[ "${SANDSSH_QUIET:-}" = 1 ] || $TS status | head -5
