#!/usr/bin/env python3
"""ProxyCommand: ssh -> this -> Cloudflare Worker (ssh_relay_worker.js)
-> the Worker's connect() -> target:22.

The Worker exposes a fixed TCP target as a WebSocket on your own
Cloudflare edge. This script dials that WebSocket (through the sandbox
egress proxy, which must allow CONNECT to the worker's host:443) and
splices ssh's stdin/stdout to the WebSocket byte stream, so `ssh` sees a
plain TCP pipe to the target.

Usage as ProxyCommand:
  ssh -o ProxyCommand='python3 ws_ssh_relay.py worker.example.workers.dev' \
      -o ConnectTimeout=12 railway.new

Or with the full URL and an explicit Host for TLS SNI:
  python3 ws_ssh_relay.py https://my-relay.example.workers.dev/

Stdlib only, bounded timeouts, no hangs. Egress proxy is read from the
environment; nothing is hardcoded.
"""
import base64
import os
import socket
import ssl
import struct
import sys
import threading
import time

def _egress():
    """Sandbox egress CONNECT proxy from env. Port varies per session."""
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

EGRESS = _egress()
TIMEOUT = 12
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

def log(m):
    print(f"[ws_ssh_relay {time.strftime('%H:%M:%S')}] {m}", file=sys.stderr, flush=True)

def tunnel(host, port, timeout=TIMEOUT):
    """TLS TCP to host:port, through the egress proxy if present."""
    if EGRESS:
        s = socket.create_connection(EGRESS, timeout=timeout)
        s.settimeout(timeout)
        s.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
        r = b""
        while b"\r\n\r\n" not in r:
            c = s.recv(4096)
            if not c:
                raise ConnectionError(f"egress closed: {r[:80]!r}")
            r += c
        if b" 200" not in r.split(b"\r\n")[0]:
            raise ConnectionError(f"egress refused: {r.split(chr(13).encode())[0][:80]!r}")
    else:
        s = socket.create_connection((host, port), timeout=timeout)
        s.settimeout(timeout)
    ctx = ssl.create_default_context()
    return ctx.wrap_socket(s, server_hostname=host)

def ws_connect(url, timeout=TIMEOUT):
    if "://" in url:
        rest = url.split("://", 1)[1]
    else:
        rest = url
    hostport = rest.split("/", 1)[0]
    path = "/" + (rest.split("/", 1)[1] if "/" in rest else "")
    host, _, port = hostport.partition(":")
    port = int(port or 443)
    s = tunnel(host, port, timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {hostport}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    s.sendall(req.encode())
    r = b""
    while b"\r\n\r\n" not in r:
        c = s.recv(4096)
        if not c:
            raise ConnectionError("closed during WS handshake")
        r += c
    head, _, rest_bytes = r.partition(b"\r\n\r\n")
    if b" 101" not in head.split(b"\r\n")[0]:
        raise ConnectionError(f"no 101: {head.splitlines()[0][:80]!r}")
    return s, rest_bytes

def send_frame(sock, payload, opcode=OP_BIN):
    """Client->server frames MUST be masked."""
    mask = os.urandom(4)
    n = len(payload)
    if n < 126:
        hdr = struct.pack("!BB", 0x80 | opcode, 0x80 | n)
    elif n < 65536:
        hdr = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, n)
    else:
        hdr = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(hdr + mask + masked)

def recv_exact(sock, n, buf):
    while len(buf) < n:
        c = sock.recv(65536)
        if not c:
            raise ConnectionError("closed")
        buf += c
    return buf

def recv_frame(sock, buf):
    """Return (opcode, payload, buf). Handles control frames transparently."""
    buf = recv_exact(sock, 2, buf)
    b0, b1 = buf[0], buf[1]
    opcode = b0 & 0x0F
    ln = b1 & 0x7F
    i = 2
    if ln == 126:
        buf = recv_exact(sock, 4, buf)
        ln = struct.unpack("!H", buf[2:4])[0]; i = 4
    elif ln == 127:
        buf = recv_exact(sock, 10, buf)
        ln = struct.unpack("!Q", buf[2:10])[0]; i = 10
    if b1 & 0x80:  # server should not mask, but handle it
        buf = recv_exact(sock, i + 4, buf)
        mask = buf[i:i+4]; i += 4
    else:
        mask = None
    buf = recv_exact(sock, i + ln, buf)
    payload = buf[i:i+ln]
    if mask:
        payload = bytes(b ^ mask[j % 4] for j, b in enumerate(payload))
    rest = buf[i+ln:]
    if opcode == OP_CLOSE:
        raise ConnectionError("peer close")
    if opcode == OP_PING:
        send_frame(sock, payload, OP_PONG)
        return recv_frame(sock, rest)
    if opcode == OP_PONG:
        return recv_frame(sock, rest)
    return opcode, payload, rest

def splice(sock, buf):
    """ssh stdin -> ws, and ws -> ssh stdout.

    Teardown is half-close aware. When ssh closes its stdin (end of the
    request, or a ProxyCommand input that is done) we must NOT kill the
    reader immediately: the target's reply may still be in flight, and
    dropping it would truncate the SSH session. So stdin EOF sends a WS
    close frame and marks the write side done, but the read side keeps
    draining until the socket closes. The read side ending (target closed)
    is what tears everything down.
    """
    done = threading.Event()   # set when the read side has finished

    def ws_to_stdout():
        try:
            b = buf
            while True:
                _, payload, b = recv_frame(sock, b)
                if payload:
                    pos = 0
                    while pos < len(payload):
                        pos += os.write(1, payload[pos:])
        except OSError:
            pass
        finally:
            done.set()

    def stdin_to_ws():
        try:
            while True:
                d = os.read(0, 65536)
                if not d:
                    break
                send_frame(sock, d, OP_BIN)
        except OSError:
            pass
        finally:
            # Half-close: tell the peer we are done sending, but keep
            # reading until it closes.
            try:
                send_frame(sock, b"", OP_CLOSE)
            except OSError:
                pass

    t1 = threading.Thread(target=ws_to_stdout, daemon=True)
    t2 = threading.Thread(target=stdin_to_ws, daemon=True)
    t1.start(); t2.start()
    done.wait()
    try:
        sock.close()
    except OSError:
        pass

def main():
    if len(sys.argv) < 2:
        log("usage: ws_ssh_relay.py <worker-url>")
        return 2
    url = sys.argv[1]
    log(f"connecting to worker {url}")
    sock, buf = ws_connect(url)
    log("websocket open, splicing to target")
    splice(sock, buf)
    return 0

if __name__ == "__main__":
    sys.exit(main())
