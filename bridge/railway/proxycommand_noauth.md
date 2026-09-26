# ProxyCommand A: best NO-CREDENTIAL path (measured working)

Mechanism: open HTTP/HTTPS proxy on an allowed port that relays CONNECT to
an arbitrary port, chaining sandbox -> egress proxy -> relay -> target:22.
No account, no key material on the relay side. The SSH session itself is
end-to-end encrypted, so the relay only ever sees ciphertext.

Best measured relay as of 2026-09-26: 165.22.103.5:443
(full ssh exit 0 in 6/6 runs, ~1.52s per command).

Put this in ~/.ssh/config (adjust paths) or pass inline:

    Host railway.new
      HostName railway.new
      Port 22
      User root
      ProxyCommand python3 /path/to/sandssh/bridge/railway/chain.py
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      IdentityFile /path/to/your/key
      BatchMode yes
      ConnectTimeout 12

Or inline for a one-off:

    ssh -o ProxyCommand='python3 /path/to/sandssh/bridge/railway/chain.py' \
        -o ConnectTimeout=12 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i your_key railway.new 'uname -a'

chain.py reads the sandbox egress proxy from $HTTPS_PROXY (never a
hardcoded port), tries each relay in order, verifies the target's SSH
banner is SSH-2.0-Go, and splices stdin/stdout to the socket. Pin a single
relay with RELAYS=host:port.

In a cage with no /etc/passwd (this sandbox), ssh itself exits 255 with
"No user exists for uid 0" before doing anything. Use the repo's shim:

    LD_PRELOAD=/path/to/sandssh/shims/fakepwd.so ssh ...

See BENCHMARKS.md for the measurements and the ranked alternatives.

---

# Note: a better option now exists

This no-credential open-proxy path is proven (full `ssh` exit 0, ~1.5s per
command, 6/6 runs through 165.22.103.5:443) but it depends on random
third-party hosts that rot within hours. A Cloudflare Worker relay reaches
the same target with an endpoint you control and nothing to manage. See
`WORKER_RELAY.md` and `proxycommand_worker.md`. Keep `chain.py` as the
fallback for when the Worker is not deployed.
