#!/usr/bin/env python3
"""Probe: does the sandbox egress reach <host> as a WebSocket?

Opens a CONNECT tunnel to the sandbox egress proxy (address read from
$HTTPS_PROXY, port never hardcoded), does TLS to the host, sends a
WebSocket upgrade, and prints the first status line. 101 means the WS hop
works; 301/404/426 mean you reached the origin but it did not upgrade (for
a real Worker that is a routing or health-path issue, not a tunnel issue);
403 means the egress allowlist refused it.

Usage: python3 ws101.py <host> [port]
Stdlib only, bounded timeouts, no hangs.
"""
import base64
import os
import socket
import ssl
import sys

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
    return None

def main():
    if len(sys.argv) < 2:
        print("usage: ws101.py <host> [port]")
        return 2
    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 443
    E = _egress()
    if not E:
        print("no $HTTPS_PROXY in env; cannot tunnel")
        return 3
    try:
        s = socket.create_connection(E, timeout=8)
        s.settimeout(8)
        s.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
        r = b""
        while b"\r\n\r\n" not in r:
            c = s.recv(4096)
            if not c:
                print(f"egress closed: {r[:60]!r}")
                return 4
            r += c
        if b" 200" not in r.split(b"\r\n")[0]:
            print(f"egress refused: {r.splitlines()[0][:60]!r}")
            return 4
        s = ssl._create_unverified_context().wrap_socket(s, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(
            f"GET / HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        r = b""
        while b"\r\n\r\n" not in r:
            c = s.recv(4096)
            if not c:
                print("origin closed during WS handshake")
                return 5
            r += c
        print(r.split(b"\r\n")[0].decode(errors="replace"))
        return 0
    except socket.timeout:
        print("timeout: no response within 8s")
        return 6
    except Exception as e:
        print(f"FAIL {type(e).__name__}: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
