#!/usr/bin/env python3
"""sandssh-relay -- rendezvous relay for sandssh mode B.

Both the sandbox node and the ssh client DIAL OUT to this relay; it pairs
the two and becomes a dumb ciphertext pipe. It exists to solve "no inbound,
no bind" cages: nothing behind it listens, everything is outbound TLS.

Run it anywhere an HTTPS reverse proxy can reach (caddy/nginx/Cloudflare in
front of it), or expose it directly with --tls-cert/--tls-key:

    sandssh-relay --listen :8443 --key <shared-secret>
    sandssh-relay --listen /tmp/relay.sock --key <shared-secret>   # testing

Protocol (v1), after a websocket handshake:

    node:   GET /v1/node/<name>     header X-SandSSH-Key: <secret>
    client: GET /v1/connect/<name>  header X-SandSSH-Key: <secret>

The relay queues up to --queue node dials per name; a client connect pops
one and sends b"ok" to both ends, then forwards raw websocket bytes between
them. It never reads the frames: the ssh session inside is end-to-end
encrypted between the real peers, so the relay can be dumb and untrusted.

Stdlib only. Test it without any bind permission by using a unix socket.
"""
import argparse, hmac, os, socket, ssl, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_QUEUE = 4
MAX_CONNS = 64

state_lock = threading.Lock()
pending = {}            # name -> [ws-conn objects]
conn_count = [0]


def log(msg):
    print("[relay] %s" % msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    rbufsize = 0        # unbuffered: never read past the handshake into frames
    wbufsize = 0

    def log_message(self, fmt, *args):
        pass

    def plain(self, code, text):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(text)))
        self.end_headers()
        self.wfile.write(text)

    def do_GET(self):
        key = self.headers.get("X-SandSSH-Key", "")
        want = self.server.relay_key
        if not want or not hmac.compare_digest(key, want):
            self.plain(401, "sandssh-relay: bad or missing X-SandSSH-Key\n")
            return
        parts = self.path.split("/")
        if len(parts) < 4 or parts[1] != "v1":
            self.plain(404, "sandssh-relay: not found\n"); return
        role, name = parts[2], parts[3]
        if not name.replace("-", "").replace("_", "").isalnum() or len(name) > 64:
            self.plain(400, "sandssh-relay: bad node name\n"); return

        if role == "node":
            self.register_node(name)
        elif role == "connect":
            self.connect_client(name)
        else:
            self.send_response(404); self.end_headers()

    # -- websocket handshake helpers --------------------------------------

    def ws_accept_key(self):
        import base64, hashlib
        key = self.headers.get("Sec-WebSocket-Key", "")
        if not key:
            return None
        return base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()

    def finish_upgrade(self):
        acc = self.ws_accept_key()
        if acc is None:
            self.send_response(400); self.end_headers(); return False
        self.connection.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                                 "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                 "Sec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        return True

    # -- roles -------------------------------------------------------------

    def register_node(self, name):
        if not self.finish_upgrade():
            return
        ev = threading.Event()      # set when a client pairs with us
        done = threading.Event()    # set when the pipe is finished
        with state_lock:
            q = pending.setdefault(name, [])
            while len(q) >= self.server.queue:
                dropped = q.pop(0)
                try:
                    dropped[0].close(); dropped[2].set()
                except OSError: pass
            q.append((self.connection, ev, done))
        # hold open WITHOUT reading (the pipe owns the socket once paired);
        # after pairing, hold until the pipe is done -- returning early would
        # let the HTTP handler close the socket under the pipe.
        if not ev.wait(timeout=self.server.idle_timeout):
            with state_lock:
                q = pending.get(name, [])
                if (self.connection, ev, done) in q:
                    q.remove((self.connection, ev, done))
            try: self.connection.close()
            except OSError: pass
            return
        done.wait()

    def connect_client(self, name):
        with state_lock:
            q = pending.get(name, [])
            entry = q.pop(0) if q else None
        if entry is None:
            self.plain(503, "sandssh-relay: node not connected; try again\n")
            return
        node, ev, done = entry
        if not self.finish_upgrade():
            try: node.close()
            except OSError: pass
            done.set()
            return
        with state_lock:
            pending.get(name, []).clear()
        # wake both ends: relay sends b"ok" as first frame to each
        for s in (node, self.connection):
            try:
                s.sendall(b"\x81\x02ok")      # FIN+text, len 2, "ok" (server: unmasked)
            except OSError:
                pass
        log("paired client with node %s" % name)
        ev.set()
        try:
            pipe(node, self.connection)
        finally:
            done.set()


def pipe(a, b, tag=""):
    """Forward raw bytes both ways until either side closes."""
    import os as _os
    dbg = bool(_os.environ.get("SANDSSH_RELAY_DEBUG"))
    stats = [0, 0]
    conns = [a, b]
    def one_way(src, dst, i):
        try:
            while True:
                d = src.recv(65536)
                if not d:
                    if dbg: log("pipe%s[%d] eof after %d bytes" % (tag, i, stats[i]))
                    break
                stats[i] += len(d)
                if dbg: log("pipe%s[%d] +%d" % (tag, i, len(d)))
                dst.sendall(d)
        except OSError as e:
            if dbg: log("pipe%s[%d] err %s after %d bytes" % (tag, i, e, stats[i]))
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass
    t = threading.Thread(target=one_way, args=(a, b, 0), daemon=True)
    t2 = threading.Thread(target=one_way, args=(b, a, 1), daemon=True)
    t.start(); t2.start()
    t.join(); t2.join()
    for s in conns:
        try: s.close()
        except OSError: pass


class UnixThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX
    def server_bind(self):
        try: os.unlink(self.server_address)
        except OSError: pass
        super().server_bind()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True, help="host:port or /unix/path")
    ap.add_argument("--key", default=os.environ.get("SANDSSH_RELAY_KEY", ""),
                    help="shared secret (X-SandSSH-Key); required")
    ap.add_argument("--queue", type=int, default=MAX_QUEUE)
    ap.add_argument("--idle-timeout", type=int, default=900,
                    help="seconds an unpaired node dial is held")
    ap.add_argument("--tls-cert", default=None)
    ap.add_argument("--tls-key", default=None)
    args = ap.parse_args()
    if not args.key:
        sys.exit("refusing to run without --key/SANDSSH_RELAY_KEY")

    if args.listen.startswith("/"):
        srv = UnixThreadingHTTPServer(args.listen, Handler)
    else:
        host, port = args.listen.rsplit(":", 1)
        srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.relay_key = args.key
    srv.queue = max(1, min(args.queue, 16))
    srv.idle_timeout = args.idle_timeout
    if args.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    log("listening on %s (queue %d)" % (args.listen, srv.queue))
    srv.serve_forever()


if __name__ == "__main__":
    main()
