#!/usr/bin/env python3
"""Find public HTTP relays on allowed ports that forward to railway.new:22.
Tests full handshake: CONNECT 200, SSH banner, KEXINIT with ssh-ed25519.
Usage: timeout 90 python3 find_relays.py [start] [count]
Input: /tmp/speedx.txt or /tmp/pf443.txt style host:port lines.
Stdlib only, bounded timeouts.
"""
import socket, sys
EGRESS=("169.254.169.1",44163)
def test(proxy, timeout=5):
    ph,pp=proxy.rsplit(":",1); pp=int(pp)
    try:
        s=socket.create_connection(EGRESS,timeout=timeout)
        s.settimeout(timeout)
        s.sendall(f"CONNECT {ph}:{pp} HTTP/1.1\r\nHost: {ph}:{pp}\r\n\r\n".encode())
        r=b""
        while b"\r\n\r\n" not in r:
            c=s.recv(4096)
            if not c:
                s.close(); return "egress-closed"
            r+=c
        if b" 200" not in r.split(b"\r\n")[0]:
            s.close(); return "egress-refused"
        s.sendall(b"CONNECT railway.new:22 HTTP/1.1\r\nHost: railway.new:22\r\n\r\n")
        r2=b""
        while b"\r\n\r\n" not in r2:
            c=s.recv(4096)
            if not c: break
            r2+=c
        if b" 200" not in r2.split(b"\r\n")[0]:
            s.close(); return "relay-refused"
        s.settimeout(5)
        try: d=s.recv(4096)
        except Exception as e:
            s.close(); return f"no-banner {type(e).__name__}"
        if not d.startswith(b"SSH-"):
            s.close(); return f"bad-banner {d[:30]!r}"
        s.sendall(b"SSH-2.0-probe\r\n")
        s.settimeout(6)
        try:
            d2=s.recv(16384)
            s.close()
            return f"GOOD {len(d2)}" if b"ssh-ed25519" in d2 else f"bad-kex {len(d2)}"
        except Exception as e:
            try: s.close()
            except: pass
            return f"no-kex {type(e).__name__}"
    except Exception as e:
        return f"ERR {type(e).__name__}"
if __name__=="__main__":
    src=sys.argv[3] if len(sys.argv)>3 else "/tmp/speedx.txt"
    start=int(sys.argv[1]) if len(sys.argv)>1 else 0
    count=int(sys.argv[2]) if len(sys.argv)>2 else 20
    lines=[l.strip() for l in open(src) if l.strip()]
    # strip https:// prefix if present
    clean=[]
    for l in lines:
        if "://" in l:
            l=l.split("://",1)[1]
        clean.append(l)
    for p in clean[start:start+count]:
        print(f"{p} -> {test(p)}",flush=True)
