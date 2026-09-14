#!/usr/bin/env python3
"""sandssh-relay -- raw rendezvous relay for sandssh mode B.

Both the sandbox node and the ssh client dial OUT; the relay pairs the two
connections and splices raw bytes. The ssh session inside is end-to-end
encrypted between the real peers, so the relay is a dumb ciphertext pipe:
the simpler it is, the fewer ways it can stall.

Protocol (v2, plain bytes after TCP/TLS -- no websocket layer):

    node:   connect, send "SANDSSH1 n <name>\\n<key>\\n"   -> waits
    client: connect, send "SANDSSH1 c <name>\\n<key>\\n"   -> pairs

    relay answers each side with "OK\\n", then splices bytes until EOF.
    Unknown/failed handshakes get "ERR <reason>\\n" and a close.

Deploy behind a TLS terminator (caddy layer4 / nginx stream) on any port
the cage's egress policy allows, or expose directly with --tls-cert/--tls-key.
A unix socket path makes it testable in bindless cages.

    sandssh-relay --listen :8443 --key <secret>
    sandssh-relay --listen /tmp/relay.sock --key <secret>     # testing
"""
import argparse, hmac, os, socket, ssl, sys, threading

MAX_QUEUE = 4
MAX_IDLE = 900            # seconds an unpaired node dial is held

state_lock = threading.Lock()
pending = {}              # name -> [(conn, paired_event, done_event)]


def log(msg):
    print("[relay %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


import time


def recv_line(conn):
    """read one \\n-terminated line (max 512)"""
    buf = b""
    while b"\n" not in buf:
        c = conn.recv(256)
        if not c:
            raise ConnectionError("closed during handshake")
        buf += c
        if len(buf) > 512:
            raise ConnectionError("handshake line too long")
    line, buf2 = buf.split(b"\n", 1)
    # any bytes after the first line belong to the stream; push them back is
    # impossible on a socket -- the protocol requires the peer to send the
    # handshake as its first write and WAIT for OK before ssh bytes, so
    # leftover data here means a protocol violation.
    if buf2:
        raise ConnectionError("unexpected data after handshake line")
    return line.decode("latin1").rstrip("\r")


def handle(conn):
    buf = bytearray()
    def rline():
        nonlocal buf
        while b"\n" not in buf:
            c = conn.recv(4096)
            if not c:
                raise ConnectionError("closed during handshake")
            buf += c
            if len(buf) > 1024:
                raise ConnectionError("handshake too long")
        ln, buf = buf.split(b"\n", 1)
        return ln.decode("latin1").rstrip("\r")
    try:
        line = rline()
    except ConnectionError:
        conn.close(); return
    parts = line.split(" ")
    if len(parts) != 3 or parts[0] != "SANDSSH1" or parts[1] not in ("n", "c"):
        conn.sendall(b"ERR bad handshake\n"); conn.close(); return
    role, name = parts[1], parts[2]
    try:
        key = rline()
    except ConnectionError:
        conn.close(); return
    if not hmac.compare_digest(key, SERVER_KEY):
        conn.sendall(b"ERR bad key\n"); conn.close(); return
    if not name.replace("-", "").replace("_", "").isalnum() or len(name) > 64:
        conn.sendall(b"ERR bad name\n"); conn.close(); return

    if role == "n":
        ev, done = threading.Event(), threading.Event()
        with state_lock:
            q = pending.setdefault(name, [])
            while len(q) >= MAX_QUEUE:
                _, _, d0 = q.pop(0)
                d0.set()
            q.append((conn, ev, done))
        log("node %s waiting" % name)
        if not ev.wait(timeout=MAX_IDLE):
            with state_lock:
                q = pending.get(name, [])
                if (conn, ev, done) in q:
                    q.remove((conn, ev, done))
            try: conn.close()
            except OSError: pass
            return
        done.wait()            # keep the socket until the splice is over
        return

    # client
    with state_lock:
        q = pending.get(name, [])
        entry = q.pop(0) if q else None
    if entry is None:
        conn.sendall(b"ERR node not connected; retry\n"); conn.close(); return
    node, ev, done = entry
    conn.sendall(b"OK\n")
    node.sendall(b"OK\n")
    ev.set()
    log("paired client with node %s" % name)
    try:
        splice(node, conn)
    finally:
        done.set()


def splice(a, b):
    def one_way(src, dst, name):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    break
                dst.sendall(d)
        except OSError:
            pass
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass
    t1 = threading.Thread(target=one_way, args=(a, b, "n>c"), daemon=True)
    t2 = threading.Thread(target=one_way, args=(b, a, "c>n"), daemon=True)
    t1.start(); t2.start()
    t1.join(); t2.join()
    for s in (a, b):
        try: s.close()
        except OSError: pass


SERVER_KEY = ""


class RawServer:
    def __init__(self, sock):
        self.sock = sock

    def serve_forever(self):
        while True:
            conn, _ = self.sock.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()


class UnixRawServer(RawServer):
    def __init__(self, path):
        try: os.unlink(path)
        except OSError: pass
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(path)
        s.listen(16)
        super().__init__(s)


def main():
    global SERVER_KEY
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="host:port or /unix/path")
    ap.add_argument("--key", default=os.environ.get("SANDSSH_RELAY_KEY", ""))
    ap.add_argument("--tls-cert", default=None)
    ap.add_argument("--tls-key", default=None)
    args = ap.parse_args()
    if not args.key:
        sys.exit("refusing to run without --key/SANDSSH_RELAY_KEY")
    SERVER_KEY = args.key

    if args.listen.startswith("/"):
        srv = UnixRawServer(args.listen)
    else:
        host, port = args.listen.rsplit(":", 1)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((host, int(port)))
        s.listen(16)
        srv = RawServer(s)
    if args.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        srv.sock = ctx.wrap_socket(srv.sock, server_side=True)
    log("listening on %s" % args.listen)
    srv.serve_forever()


if __name__ == "__main__":
    main()
