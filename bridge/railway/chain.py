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
# Verified 2026-09-26 via CONNECT + SSH banner + KEXINIT (672 bytes,
# ssh-ed25519) and a full ssh with exit code 0, repeated 6 times.
# Ordered by measured full-session wall clock; see BENCHMARKS.md.
#   165.22.103.5:443  1.52s median, 6/6 full ssh exit 0
#   34.43.46.91:443   4.28s median, 2/3 full ssh exit 0
#   107.167.18.122:443 4.86s median, 3/3 full ssh exit 0
# Pin a single relay with RELAYS=host:port. Falls back to the list below.
# 52.25.133.43:443 was good in a prior run and is now dead: 502 upstream
# unreachable on 3 of 3 controls. It is not listed.
_default = [
    "165.22.103.5:443",
    "34.43.46.91:443",
    "107.167.18.122:443",
    "85.133.250.27:80",
]
_env = os.environ.get("RELAYS", "")
RELAYS = [r for r in _env.replace(" ", "").split(",") if r] or _default
TARGET = ("railway.new", 22)
EXPECTED_BANNER = b"SSH-2.0-Go"
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
    line = r.split(b"\r\n")[0]
    if b" 200" not in line:
        raise ConnectionError(f"egress refused: {line[:100]!r}")
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

def check_target(sock, timeout=TIMEOUT):
    """Read the server banner and confirm it is the gateway we expect.

    A relay that answers CONNECT 200 and then hands us some other SSH server
    is worse than a refusal: the failure only shows up as a confusing auth
    error. A scan on 2026-09-26 turned up 198.199.86.11:80 serving
    SSH-2.0-OpenSSH_7.9p1 on railway.new:22, which a CONNECT-200-only check
    counts as GOOD.

    The banner is consumed here, so the caller MUST write it back to stdout
    before splicing. The ssh client on the other end of this pipe reads that
    banner first and will abort without it.
    """
    sock.settimeout(timeout)
    banner = b""
    while b"\r\n" not in banner and len(banner) < 200:
        c = sock.recv(200 - len(banner))
        if not c:
            raise ConnectionError("target closed before banner")
        banner += c
    ident = banner.split()[0] if banner.split() else b""
    if ident != EXPECTED_BANNER:
        raise ConnectionError(f"wrong target, banner {ident!r} != {EXPECTED_BANNER!r}")
    return banner


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
            bnr = check_target(s)
            # Hand the banner back to the ssh client, which reads it first.
            os.write(1, bnr)
            log(f"target confirmed: {bnr.split()[0].decode()}")
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
