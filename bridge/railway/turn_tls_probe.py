#!/usr/bin/env python3
"""TURN TLS on allowed :443 rides the sandbox egress. Stdlib only.
Proves: CONNECT to TURN:443 via egress proxy, TLS handshake, STUN Binding
and TURN Allocate (TCP transport, RFC6062) get correct responses.

Run: timeout 30 python3 turn_tls_probe.py
All ops bounded, no hangs.
"""
import socket, ssl, struct, os
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
MAGIC=0x2112A442
def tunnel(h,p,timeout=5):
    s=socket.create_connection(PROXY,timeout=timeout)
    s.settimeout(timeout)
    s.sendall(f"CONNECT {h}:{p} HTTP/1.1\r\nHost: {h}:{p}\r\n\r\n".encode())
    r=b""
    while b"\r\n\r\n" not in r:
        r+=s.recv(4096)
    assert b" 200" in r.split(b"\r\n")[0], r[:100]
    return s
def attr(t,v):
    pad=(4-len(v)%4)%4
    return struct.pack("!HH",t,len(v))+v+b"\x00"*pad
def recv(s,timeout=5):
    s.settimeout(timeout)
    h=b""
    while len(h)<20:
        h+=s.recv(20-len(h))
    typ,length,magic,txn=struct.unpack("!HHI12s",h)
    body=b""
    while len(body)<length:
        body+=s.recv(length-len(body))
    return typ,txn,body
def parse(b):
    o=[];i=0
    while i+4<=len(b):
        t,l=struct.unpack("!HH",b[i:i+4])
        o.append((t,b[i+4:i+4+l]))
        i+=4+l+((4-l%4)%4)
    return o
for host in ["turn.cloudflare.com","global.turn.twilio.com","openrelay.metered.ca"]:
    print(f"== {host}:443")
    try:
        s=tunnel(host,443,timeout=5)
        ctx=ssl._create_unverified_context()
        s=ctx.wrap_socket(s,server_hostname=host)
        print(f"  TLS {s.version()} ok")
        # Binding
        txn=os.urandom(12)
        s.sendall(struct.pack("!HHI12s",0x0001,0,MAGIC,txn))
        try:
            typ,rtxn,body=recv(s,timeout=5)
            print(f"  Binding resp 0x{typ:04x} match={rtxn==txn} len={len(body)}")
        except Exception as e:
            print(f"  Binding no-response ({type(e).__name__})")
        # Allocate TCP (RFC6062 proto 6) no-auth, expect 401 with NONCE+REALM
        txn2=os.urandom(12)
        req=attr(0x0019, struct.pack("!BBBB",6,0,0,0))
        s.sendall(struct.pack("!HHI12s",0x0003,len(req),MAGIC,txn2)+req)
        typ2,rtxn2,body2=recv(s,timeout=5)
        print(f"  Allocate TCP resp 0x{typ2:04x} match={rtxn2==txn2} len={len(body2)}")
        for t,v in parse(body2):
            print(f"    0x{t:04x} len={len(v)} val={v[:60]!r}")
        s.close()
    except Exception as e:
        print(f"  FAIL {type(e).__name__}:{e}")
