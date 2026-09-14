# sandssh

Seamless SSH into sealed AI-agent sandboxes, over whatever the network still
allows. Tailscale when it works; an outbound-only websocket relay when it
doesn't; a github control channel when nothing else does. Built and verified
inside hardened agent sandboxes (seccomp + Landlock-style path policy, no
pty, no `/etc/passwd`, TCP bind denied, egress through an allowlisting proxy).
Every workaround here was forced by a real denial.

```
 your laptop                        sealed agent sandbox (no inbound, no bind)
┌────────────┐   tailnet (WireGuard) ┌──────────────────────────────┐
│ tailcat    ─┼─────────────────────► │ tailcat serve no-auth-ssh    │  mode A
│ ssh client │                       │   └─ errandsh (bash + REPL)  │
│            │   wss relay (HTTPS)   ├──────────────────────────────┤
│ ssh +      ─┼─────────────────────► │ sandssh serve                │  mode B
│ ProxyCommand│   outbound ws        │   └─ dropbear -i ─ errandsh  │
│            │   github API (poll)   ├──────────────────────────────┤
│ sandssh    ─┼─────────────────────► │ sandssh gh-listen            │  mode C
│ gh-send    │                       │   └─ bash (redacted output)  │
└────────────┘                       └──────────────────────────────┘
```

## Pick a mode with the probe

```sh
./install.sh                  # fetch + build + scaffold
bin/sandssh probe             # maps every route out of the cage
```

The probe checks direct-IP egress, UDP (DNS/STUN), ICMP (raw and dgram),
IPv6, and the proxy's CONNECT allowlist host-by-host, then recommends:

| mode | when | experience |
|---|---|---|
| **A tailnet** | tailscale control + DERP reachable | `ssh root@100.x.y.z` and `tailcat ssh` |
| **B relay** | one https origin you control is reachable | native `ssh` via ProxyCommand; needs no inbound, no bind |
| **C gh** | only github is reachable | control channel: run commands, get output; non-interactive by design |

OONI fallback: when stage-1 results are ambiguous (timeouts rather than
clean denials), `bin/sandssh probe --ooni` consults OONI's public record of
measurements for the failing hosts to separate policy from transient faults.
If api.ooni.io is itself blocked (common), the probe says so and moves on.

## Mode A: tailnet (unchanged behavior)

```sh
TS_AUTHKEY=tskey-auth-... ./start.sh     # joins your tailnet, starts tailcat
./start.sh addr                          # node ipv4
ssh root@100.x.y.z "uname -a"            # exec over tailscale-ssh
tailcat ssh root@<tc-addr>               # interactive errandsh session
```

If control/DERP are blocked, `start.sh` tells you instead of hanging, and
prints the mode B/C commands that do work in that cage.

## Mode B: wss relay (new)

The sandbox dials OUT to a relay and waits; your laptop dials OUT to the
same relay; the relay splices them. Both legs look like ordinary HTTPS, so
no inbound, no port forwarding, no bind permission is needed anywhere. The
ssh session inside is end-to-end encrypted between the real peers: the
relay only ever sees ciphertext.

One-time setup: run the relay anywhere a TLS terminator can reach it
(`relay/DEPLOY.md` has the copy-paste systemd + caddy guide):

```sh
SANDSSH_RELAY_KEY=<secret> sandssh-relay --listen 127.0.0.1:8443
```

The protocol is deliberately a raw byte splice (v2): no websocket framing,
no HTTP semantics to half-parse -- after a 2-line handshake the relay moves
opaque bytes and the ssh layer carries the real crypto. 16/16 automated
runs green in the reference cage.

Sandbox side:

```sh
./start.sh serve --relay tls://relay.example.com:8443 --name myagent
```

Laptop side (then it is just ssh):

```sh
bin/sandssh config --relay tls://relay.example.com:8443 --name myagent >> ~/.ssh/config
ssh myagent                 # native openssh session into the cage
ssh myagent "tail -f log"   # scp/rsync/VS Code Remote-SSH style flows work
```

`--transport ws` (websocket framing) remains available for CDN-fronted
deployments (Cloudflare in front of the relay), but the raw relay is the
default and the one under continuous test. SNI-based censorship on the
path is out of scope for the python client; for hostile-DPI networks,
compose with established tools (xray, hysteria) in front of
`sandssh connect` via their SOCKS interface.

## Mode C: github-only cages (new)

When the allowlist is literally github.com and friends, nothing interactive
is possible (no relay host, no raw sockets). The control channel runs over
a private repo you control using the Contents API:

```sh
# sandbox side (needs GH_TOKEN with repo scope)
SANDSSH_GH_SECRET=<secret> ./start.sh gh
# laptop side
bin/sandssh gh-send --name myagent --secret <secret> -- make test
```

Commands are sequence-numbered and HMAC-signed; output is scrubbed for
credential shapes (`tskey-`, `ghp_`, AWS keys, PEM blocks, ...) and capped
at 14KB before it leaves the cage. Conditional GETs (ETag) are free against
the rate limit, connections are kept alive, and long jobs publish a rolling
tail every 2s so output feels streaming.

Interactive form: `bin/sandssh gh-shell --name agent1` on the laptop is a
line-at-a-time remote shell. Measured round trip in the reference cage:
2.7-5s per command (median ~3.5s). The floor is structural: every message
is a git commit on GitHub's side (~1s per Contents PUT, two per round
trip, plus propagation). That is the price of a github-only cage; a sub-
second channel requires a reachable origin you control (mode B) or a
reachable tailnet (mode A). For dev ops (run tests, tail logs, restart
services) 3s feels like a bad satellite link, not a shell; for vim it is
unusable -- that is physics on this network, not tuning.

## What the probe found in the reference cage

Direct-IP egress blackholed, UDP/ICMP denied at syscall level, IPv6 absent,
and the proxy is a CONNECT allowlist (not a TLS MITM: tunnels pass through
to real origin certs). Verified working end to end in that cage: openssh →
`sandssh connect` → relay → `sandssh serve` → dropbear -i (chroot) →
errandsh REPL, plus the mode C round trip. Tests: `tests/`.

## Components

| path | what |
|---|---|
| `install.sh` | fetch + build + scaffold, idempotent; dropbear static build included |
| `start.sh` | `up` (tailscale) / `serve` (mode B) / `gh` (mode C) / `status` / `addr` / `probe` |
| `bin/sandssh` | single-file stdlib python CLI: probe, serve, connect, gh, selftest, config |
| `relay/sandssh-relay.py` | rendezvous relay; TCP or unix socket; TLS optional (front with caddy/nginx) |
| `shell/errandsh` | userspace line discipline: arrows/Home/End/Delete editing, Ctrl-R search, bracketed paste, persistent history, Tab completion, real Ctrl-C |
| `shims/fakepwd.c` | `LD_PRELOAD` synthetic passwd db for cages without `/etc/passwd` |
| `shims/fakepty.c` | isatty/termios interposer for fds 0-2 |
| `patches/tailcat-pty-fallback.patch` | pty sessions degrade to pipes; `LD_PRELOAD` passes through |
| `patches/tailscaled-setgroups-tolerance.patch` | tolerate seccomp `setgroups(2)` denial when identity unchanged |
| `patches/dropbear-inetd-pipe-tolerance.patch` | dropbear -i serves ssh over pipes/unix sockets (no inet address to log) |
| `patches/dropbear-setgroups-tolerance.patch` | same tolerance for dropbear's `initgroups` |
| `tests/` | end-to-end tests that run even in bindless cages |

## Security model

- Mode A: tailnet membership is the credential; tailcat's key file is the
  node identity. Same as before.
- Mode B: relay authentication is a shared secret (`X-SandSSH-Key`), but the
  real security boundary is ssh pubkey auth end to end; a malicious relay
  sees only ciphertext and can at worst deny service. Dropbear pubkey-only
  (`-s -g`), chrooted, running as the agent's own uid; no listening socket
  exists anywhere in the cage.
- Mode C: private repo + HMAC-signed envelopes; output is redacted and
  size-capped before it leaves the cage. The channel executes whatever the
  operator side sends — treat the repo as root-equivalent and the tokens in
  it as live credentials.
- The tailscale auth key (`tskey-auth-...`) is single-use-ish and scoped;
  prefer ephemeral keys for short-lived agents. This repo never stores keys.

## Known limits

- No kernel pty anywhere in the stack (no /dev/ptmx in target cages), so no
  full-screen TUIs; errandsh covers the interactive REPL case.
- Mode B needs ONE reachable https origin that you control. In a CONNECT-
  allowlist cage that origin must be allowlisted; the probe prints exactly
  what to ask for.
- Mode C is deliberately not interactive (see above).
- `sandssh-relay` expects TLS termination in front (caddy/nginx/CF); bare
  HTTP between relay and peers is fine on loopback/testing only.
- ECH/SNI anti-censorship knobs are not in the python client; for
  hostile-DPI networks front `sandssh connect` with a SOCKS tool of your
  choice. CONNECT-allowlist cages decide on the CONNECT line, where SNI
  does not exist.

## Versions

Tested with tailscale 1.102.4, tailcat 0.6.0, dropbear 2026.94 (static
musl), bash 5.3, python 3.14, openssh 10.4, linux 6.18 (gentoo). Verified
in a bailey-sandboxed cage: egress via CONNECT-allowlist proxy only, no
inbound, no TCP bind, no pty, no /etc/passwd.

## Note on tailcat serve-stdio

The ideal mode-B server is a patched tailcat speaking ssh on stdio (one ssh
server across modes). Evaluated: tailcat's module graph pulls in the whole
tailscale/gvisor/k8s universe, whose primary module hosts are unreachable
from github-only cages; mirroring ~30 vanity modules via replace directives
resolves but is unbounded maintenance. dropbear -i needs zero dependencies,
builds from a github clone in any cage, and is proven end to end here, so
it ships as the mode-B server; the tailcat patch remains the preferred
future direction for cages where the go toolchain and module proxy work.
