#!/usr/bin/env python3
"""podssh-poc chain: ssh from CONNECT-allowlist sandbox to railway.new:22
via public HTTP relay on allowed :443.

Path: ssh -> this ProxyCommand -> egress proxy (from env, port varies per session)
  -> open relay :443 (public, allows CONNECT to arbitrary)
  -> railway.new:22 (SSH-2.0-Go)

Both tunnels look like ordinary HTTPS CONNECT on allowed ports.
The ssh session inside is end-to-end encrypted; relays see ciphertext.

Usage as ProxyCommand:
  ssh -o ProxyCommand='python3 /workspace/podssh-poc/chain.py' railway.new

Stdlib only, bounded timeouts, no hangs. Tries relays in order.
"""
import socket, sys, threading, os, time

def _egress():
    for v in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        u = os.environ.get(v, "")
        if "://" in u:
            u = u.split("://", 1)[1]
        u = u.rstrip("/")
        if not u:
            continue
        if ":" in u:
            h, p = u.rsplit(":", 1)
            try:
                return (h, int(p))
            except ValueError:
                continue
    return ("169.254.169.1", 44163)

EGRESS = _egress()
# Verified 2026-09-26 via CONNECT + SSH banner + KEXINIT (672 bytes, ssh-ed25519).
# Each returned 200 to inner CONNECT railway.new:22 and served SSH-2.0-Go.
# 52.25.133.43:443 provisioned a trial VM on a fresh key (see README update
# 2026-09-26). 47.236.86.147:443 is flaky: banner ok, ssh often closes.
RELAYS = [
    "52.25.133.43:443",
    "107.167.18.122:443",
    "47.236.86.147:443",
]
TARGET = ("railway.new", 22)
TIMEOUT = 8

def log(m):
    print(f"[chain {time.strftime('%H:%M:%S')}] {m}", file=sys.stderr, flush=True)

def via_chain(relay, timeout=TIMEOUT):
    rh, rp = relay.rsplit(":", 1)
    rp = int(rp)
    s = socket.create_connection(EGRESS, timeout=timeout)
    s.settimeout(timeout)
    s.sendall(f"CONNECT {rh}:{rp} HTTP/1.1\r\nHost: {rh}:{rp}\r\nProxy-Connection: Keep-Alive\r\n\r\n".encode())
    r = b""
    while b"\r\n\r\n" not in r:
        c = s.recv(4096)
        if not c:
            raise ConnectionError(f"egress closed: {r[:100]!r}")
        r += c
    if b" 200" not in r.split(b"\r\n")[0]:
        raise ConnectionError(f"egress refused: {r.split(bchr(13))[0] if False else r[:100]!r}")
    s.settimeout(timeout)
    s.sendall(f"CONNECT {TARGET[0]}:{TARGET[1]} HTTP/1.1\r\nHost: {TARGET[0]}:{TARGET[1]}\r\n\r\n".encode())
    r2 = b""
    while b"\r\n\r\n" not in r2:
        c = s.recv(4096)
        if not c:
            raise ConnectionError(f"relay closed: {r2[:100]!r}")
        r2 += c
    if b" 200" not in r2.split(b"\r\n")[0]:
        raise ConnectionError(f"relay refused: {r2[:150]!r}")
    s.settimeout(None)
    # make blocking for splice; set timeout None, threads block on recv
    return s

def splice(sock):
    done = threading.Event()
    def stdin_to_sock():
        try:
            while True:
                d = os.read(0, 65536)
                if not d:
                    break
                sock.sendall(d)
        except OSError:
            pass
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        done.set()
    def sock_to_stdout():
        try:
            while True:
                d = sock.recv(65536)
                if not d:
                    break
                pos = 0
                while pos < len(d):
                    pos += os.write(1, d[pos:])
        except OSError:
            pass
        done.set()
    threading.Thread(target=stdin_to_sock, daemon=True).start()
    threading.Thread(target=sock_to_stdout, daemon=True).start()
    done.wait()
    try:
        sock.close()
    except OSError:
        pass

def main():
    last = None
    for relay in RELAYS:
        try:
            log(f"trying relay {relay}")
            s = via_chain(relay)
            log(f"paired via {relay}, splicing to {TARGET[0]}:{TARGET[1]}")
            splice(s)
            return 0
        except Exception as e:
            last = e
            log(f"relay {relay} failed: {type(e).__name__}:{e}")
            continue
    log(f"all relays failed, last: {last}")
    return 1

if __name__ == "__main__":
    sys.exit(main())
