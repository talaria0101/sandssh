# ProxyCommand B: CREDENTIALED / SERVERLESS path (Cloudflare Worker) -- the recommended one

This replaces what I first wrote here. I originally said the credentialed
TURN path was the answer and that Cloudflare could not help. Both were
wrong. The correct serverless design needs no TURN server at all.

See WORKER_RELAY.md for the full write-up. Short version:

    ssh -> ws_ssh_relay.py -> egress proxy (CONNECT 443)
      -> your Cloudflare Worker (ssh_relay_worker.js, on *.workers.dev)
      -> Worker connect() -> railway.new:22

The Worker is an ordinary Cloudflare Worker using the runtime `connect()`
API, which is a plain outbound TCP socket. Its docs name SSH as a
supported protocol. It dials the public target directly. There is no VPC,
no Mesh, no Tunnel, no connector on the target's network, and no TURN
server anywhere in the path. Cloudflare hosts the endpoint on 443, which
this sandbox's egress proxy already allows (measured: `workers.dev:443`
returns `HTTP/1.1 200 Connection Established`).

Deploy with `npx wrangler deploy` (needs a Cloudflare account; there are no
CF credentials in this sandbox, so this step is on your machine).

Usage once deployed to https://ssh-relay.<you>.workers.dev:

    ssh -o ProxyCommand='python3 ws_ssh_relay.py https://ssh-relay.<you>.workers.dev' \
        -o ConnectTimeout=12 -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i your_key railway.new 'uname -a'

Why this beats the open-proxy chain (chain.py) even though chain.py is
already proven to exit 0 here: chain.py depends on a random, untrusted,
perishable third-party host. The Worker is a fixed endpoint you control,
on Cloudflare's edge, with a stable URL and a status page. Same latency
class, one order of magnitude better reputation on the ranking axis that
matters once things break.

The earlier TURN findings still stand and are kept below as the negative
result they are: Cloudflare Realtime's managed TURN does not implement
RFC 6062, so it cannot relay TCP. The answer was never to get a TURN server
onto Cloudflare; it was to use the Worker's own TCP socket.

STATUS OF THE OLD TURN ANALYSIS (unchanged, still correct as a negative):

- turn.cloudflare.com:443 answers a no-auth Allocate with NONCE and REALM
  but its docs say "Realtime does not implement RFC6062 and will not
  respect REQUESTED-TRANSPORT STUN attribute", and its feature matrix
  lists "TCP relaying TURN extension: No".
- Tailscale DERP, Twingate (needs TCP 30000-31000 + UDP), pwnat (needs
  UDP+ICMP and a server you run) and sandssh mode B (needs your origin on
  the egress allowlist) were each assessed and none of them reach a public
  TCP target from this sandbox. Details are in BENCHMARKS.md.

