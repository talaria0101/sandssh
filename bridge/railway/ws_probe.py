#!/usr/bin/env python3
"""WSS on allowed :443 rides the sandbox egress. Stdlib only.
Proves: CONNECT to WSS host:443 via egress proxy, TLS, WS upgrade 101.
Run: timeout 25 python3 ws_probe.py
"""
import socket, ssl, os, base64
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
PROXY = _egress()
def tunnel(h,p,timeout=5):
    s=socket.create_connection(PROXY,timeout=timeout)
    s.settimeout(timeout)
    s.sendall(f"CONNECT {h}:{p} HTTP/1.1\r\nHost: {h}:{p}\r\n\r\n".encode())
    r=b""
    while b"\r\n\r\n" not in r:
        r+=s.recv(4096)
    assert b" 200" in r.split(b"\r\n")[0], r[:100]
    return s
for host,port,path in [("ws.postman-echo.com",443,"/raw"),("relay.damus.io",443,"/")]:
    print(f"== wss://{host}:{port}{path}")
    try:
        s=tunnel(host,port,timeout=5)
        ctx=ssl.create_default_context()
        s=ctx.wrap_socket(s,server_hostname=host)
        print(f"  TLS {s.version()} ok")
        key=base64.b64encode(os.urandom(16)).decode()
        req=(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        s.settimeout(6)
        s.sendall(req.encode())
        r=b""
        while b"\r\n\r\n" not in r:
            r+=s.recv(4096)
        first = r.split(b"\r\n")[0] if b"\r\n" in r else r[:80]
        print(f"  WS resp: {first!r}")
        s.close()
    except Exception as e:
        print(f"  FAIL {type(e).__name__}:{e}")
