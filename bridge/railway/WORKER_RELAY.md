# Serverless SSH relay on a Cloudflare Worker

A plain Cloudflare Worker that fronts a fixed TCP target (an SSH gateway on
port 22) as a WebSocket on your own Cloudflare edge, and splices raw bytes
between that WebSocket and the target over the runtime's `connect()` API.
From a sandbox whose egress proxy only allows HTTPS, `ssh` reaches a
TCP-only host through it. No VPC, no Tunnel, no Mesh node, no server to
run, nothing to keep alive. Cloudflare hosts it on 443.

## Why this is the right shape

- `connect()` is Cloudflare's outbound TCP socket API. Its docs name SSH as
  a supported protocol. It is not tied to Cloudflare's own network: it dials
  any public host and port, so a public target like `railway.new:22` works
  with no connector, tunnel, or private network involved.
- HTTP-triggered Workers have no wall-clock duration limit, so a long-lived
  WebSocket relay is fine. The relay is I/O bound and barely uses CPU; the
  Free plan's 10ms CPU per request is not a constraint for a byte splice.
- The whole thing is one file plus `wrangler.toml`, both in this directory.

## Files

- `ssh_relay_worker.js` - the Worker. Pinned target in `CFG` at the top.
- `wrangler.toml` - deploy config.
- `ws_ssh_relay.py` - the client-side ProxyCommand. Dials the Worker over
  WebSocket (through the sandbox egress proxy) and splices `ssh`'s
  stdin/stdout to it. Stdlib only.

## Deploy

You need a Cloudflare account and `wrangler` (`npx wrangler login`). There
are no Cloudflare credentials in the sandbox, so this step runs on your
machine, not here.

    cd bridge/railway
    npx wrangler deploy

Wrangler prints a URL like `https://ssh-relay.<you>.workers.dev`. Edit
`CFG.host` / `CFG.port` / `CFG.banner` in `ssh_relay_worker.js` first if the
target is not `railway.new:22`.

Health check (any non-WebSocket GET returns JSON):

    curl -s https://ssh-relay.<you>.workers.dev
    # {"ok":true,"target":"railway.new:22"}

## Use from the sandbox

    ssh -o ProxyCommand='python3 bridge/railway/ws_ssh_relay.py https://ssh-relay.<you>.workers.dev' \
        -o ConnectTimeout=12 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i your_key railway.new 'uname -a'

The sandbox egress must allow CONNECT to the Worker's host on 443. It does:
`workers.dev:443` and `trycloudflare.com:443` both return
`HTTP/1.1 200 Connection Established` from the sandbox (measured).

In this sandbox `ssh`/`ssh-keygen`/`scp` also need the passwd shim because
there is no `/etc/passwd`:

    LD_PRELOAD=/path/to/sandssh/shims/fakepwd.so ssh ...

## What is verified and what is not

Verified in this sandbox (no Cloudflare account needed):
- `ssh_relay_worker.js` parses under `node --check`.
- `ws_ssh_relay.py` RFC 6455 codec passes a frame suite (masked client
  frames, 7/16/64-bit lengths, PING/PONG, CLOSE, leftover-buffer handling).
- End to end against a stdlib WebSocket server on a unix socket that
  emulates the Worker: the client completes the upgrade, relays the target
  banner to stdout, and round-trips payloads of 1 to 200,000 bytes
  byte-identical, including across the 126 and 65536 frame boundaries, with
  correct half-close teardown. That is the exact byte behaviour `ssh`
  depends on.

Not verified, because it needs a Cloudflare account and this is a design
plus a client, not a deployment:
- The Worker actually connecting to `railway.new:22` from Cloudflare's edge.
- A full `ssh ... 'uname -a'` through a live deployed Worker returning exit 0.

To verify once deployed: run the ProxyCommand above. The Worker refuses to
relay to a target whose banner is not the `CFG.banner` it expects, so a
successful `ssh` proves the edge dial worked.

## Security

The Worker is an unauthenticated byte relay to whatever `CFG.host:CFG.port`
names. Anyone who learns the URL can open a WebSocket and reach that target
through Cloudflare. Put Cloudflare Access, a Worker-level token check, or
an IP allowlist in front of it if that matters. `CFG` pins the destination,
so this is not an open relay to arbitrary hosts.
