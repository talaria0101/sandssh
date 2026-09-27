# Railway free VM: benchmarks and usefulness, 2026-09-26

Conditions for every number below. Sandbox: Linux sandbox
6.18.39-gentoo x86_64, uid 0, no /etc/passwd, egress via CONNECT
proxy from env (port varies per session), `date -u` Sat Sep 26
13:25 to 13:32 UTC 2026. VM: fvm-85e90bb2-ca96-4d6e-b42b-7de2f9fd1f0e-1-0,
6.18.46-railway x86_64, Ubuntu 26.04.1, reached via chain.py double
CONNECT through 52.25.133.43:443. Each ssh run wrapped in
timeout 40 to 90 with ConnectTimeout 12 and BatchMode yes. Exit
codes read from the ssh process directly, never through a pipe.
Trial window: created 13:13:08Z, expires 2026-09-26T14:13:08Z.

## Shape

- Sandbox: 16 cores AMD Ryzen 7 7700, 30Gi RAM, 452G ZFS home.
  No direct TCP, no bind, no pty, proxy only.
- VM: 2 vCPU AMD EPYC 9655, 2.2Gi RAM plus 511Mi swap, 30G disk
  with 26G free (15 percent used). Full egress: VM public IP
  152.55.176.85, TCP 22 out OK, DNS returns IPv4 and IPv6
  (no ping binary to test ICMP). Root, PORT 8080.

## CPU

- Python 50k modular exponentiations: VM 0.05s, sandbox 0.03s
  (1 run each). Sandbox wins single core, and has 8x the cores.
- OpenSSL 3.5.5 aes-256-cbc, 2s per size, VM, 1 run: 16B
  740034k, 64B 800687k, 256B 900255k, 1024B 899748k,
  8192B 958250k, 16384B 969443k (numbers in KB/s).

## Disk (dd 512MiB, 1 run each, VM)

- Write with fdatasync: 537MB in 1.07s, 501 MB/s.
- Read: 537MB in 1.27s, 423 MB/s.
- Sandbox same test: 4.6 GB/s. Local ZFS wins by 9x.

## Network (VM, curl, 1 run each)

- jsdelivr jquery 87kB: 0.03s at 3.2 MB/s.
- nodejs.org node tarball 31MB: 0.21s at 146 MB/s (edge cached).
- npm install express@4, 68 packages: 5s. Node listen check ok.
- python venv plus pip install requests ok, version 2.34.2.
- gcc -O2 hello ok. docker hello-world ok (dockerd running).
- Chromium headless dump-dom of example.com ok (dbus errors
  ignorable). Playwright python module is NOT installed; use the
  system chrome at
  /root/.cache/ms-playwright/chromium-1228/chrome-linux64/chrome.

## Link cost (ssh over relay chain, 3 runs)

- `ssh railway.new 'echo hi'`: 16.8s, 14.0s, 17.4s wall clock
  per invocation. Every run pays double CONNECT plus KEX plus
  the JSON manifest. Batch commands per connection; interactive
  use over open relays is painful by structure, not tuning.

## Preview and file movement

- python http.server on 0.0.0.0:8080 binds and serves localhost.
  Caddy on 8079 serves /app/index.html when 8080 is free.
- Public preview URL from the sandbox IP returns 403 Access
  denied until claimed: only the creator relay IP can see it.
  Expected per trial limits, observed 13:15Z.
- scp through chain.py works: 48 byte test file landed in /app
  and verified by cat.

## Quota behavior (controls, all timeout bounded)

- Refused keys stay refused across relays with the same signup
  code (two keys, both relays, exit 13 each time).
- The successful fresh key reaches the same VM via either relay
  (same fvm id, exit 0). Success is sticky per key.
- A second fresh key 4 minutes later was refused on both relays
  with one shared code. Quota opens and closes over minutes on
  top of the per IP daily limit. The bypass was a fresh relay
  while quota was open, not a quota break.

## Verdict

Useful as a real net connected Linux box for builds, docker,
browser checks, and as a rendezvous host (cloudflared, TURN, or
sandssh relay) so later sessions stop depending on open proxies.
Not useful as a fast shell over this chain (14 to 17s per command),
not useful as a public demo until claimed (preview IP gated), and
short lived (60 minutes unclaimed, then deleted if never claimed).
Claim URL is printed by every connect; it lives in the thread, not
in this repo.

---

# Relay enumeration run, 2026-09-26 16:15Z to 17:00Z

Second run of the same errand, same day, later window. Machine:
`date -u` at start `Sat Sep 26 04:15:58 PM UTC 2026`, at end
`Sat Sep 26 05:00:30 PM UTC 2026`. Sandbox: Linux sandbox
6.18.54_1-gentoo x86_64, uid 0, no /etc/passwd, no /dev/ptmx, no bind, no
direct TCP, egress via HTTP CONNECT proxy read from `$HTTPS_PROXY`
(169.254.169.1, port 44099 this session, never hardcoded in any script).
All scans used a bounded thread pool of 22-24 workers and an 8s per-hop
timeout. Every exit code was read from the process that produced it, never
through a pipe. Target `railway.new:22`, banner `SSH-2.0-Go`.

## The headline result

The transport works end to end and is proven with a real `ssh` exit code
of 0, not just a CONNECT 200. A full public-key SSH session, including
running a command and getting a shell result, succeeded through an
uncredentialed open proxy. The VM reached was
`fvm-087254c6-714c-4db3-869f-5d12b17710b4-1-0`, root, Ubuntu 26.04.1,
`build_expires_at` 2026-09-26T17:56:30Z, obtained 16:56Z.

`scp` of a 2 MiB file to `/app/` through the same relay: exit 0, 2.75s,
about 730 KiB/s upload.

This corrects a reading of the earlier BENCHMARKS section in this file.
The prior run's 14.0-17.4s per ssh is not the chain's latency. It was
52.25.133.43:443, a relay that is now dead (3 of 3 controls returned
`502 upstream unreachable`). Through the current best relay the same
command takes about 1.5s.

## Scan, class 1: open proxies permitting CONNECT to arbitrary ports

Sources pulled fresh at 16:20Z: TheSpeedX/PROXY-List (http.txt, socks4.txt),
proxifly/free-proxy-list (all, http), monosans, hookzof socks5, plus seven
extra lists (vakhov/fresh-proxy-list, zloi-user/hideip.me, mmpx12,
ErcinDedeoglu, roosterkid, clarketm, sunny9577). Deduplicated by IP,
filtered to ports 80, 443, 8443 only.

    round 1: 1614 candidates, 22 workers, 131.2s -> 4 GOOD
    round 2: 13918 candidates, 24 workers,       -> 9 GOOD
    total:   15532 candidates -> 13 raw GOOD hits
    hit rate 0.08 percent

Failure taxonomy over all 15532 candidates, reusing the strings already
established by the prior run:

    relay-refused   11508   inner CONNECT answered 4xx or closed
    egress-502       3633   sandbox egress proxy could not reach upstream
    no-banner          154   CONNECT 200 then silence
    timeout            175   no response within 8s
    bad-banner          44   not an SSH server at all
    egress-refused       5   not on the sandbox egress allowlist
    GOOD                13

Only 13 of 15532 uncredentialed public proxies will relay SSH to an
arbitrary TCP port. Perishable: 52.25.133.43:443, good in the earlier run
today, was dead on 3 of 3 controls at 16:43Z.

## A false positive the old scanner would have counted as GOOD

198.199.86.11:80 returned CONNECT 200 and a correct-looking SSH banner, but
the banner was `SSH-2.0-OpenSSH_7.9p1`, not the gateway's `SSH-2.0-Go`. It
is some other host's SSH server reachable at that address. The existing
`find_relays.py` checks that the banner starts with `SSH-` and that KEXINIT
contains `ssh-ed25519`, which a real OpenSSH server satisfies, so the old
scanner grades it GOOD. `chain.py` now has `check_target()`, which requires
the exact `SSH-2.0-Go` banner and replays it to the ssh client, and this
relay is now correctly rejected. Finding this is the argument for banner
equality rather than banner shape.

## Ranked table

Ranking follows the task's axes in order: measured working now, then no
credentials, then operator reputation, then measured stability, then
latency, then terms. Measured dominates; unmeasured options are below
measured ones however reputable the operator.

| # | Mechanism | Endpoint | Auth | Evidence | Latency | Stability | Reputation | ToS |
|---|-----------|----------|------|----------|---------|-----------|------------|-----|
| 1 | Open HTTP proxy, CONNECT to any port | 165.22.103.5:443 | none | banner SSH-2.0-Go, KEXINIT 672B ssh-ed25519, full ssh exit 0 x6, `echo t` -> `t` | 1.52s median full ssh (3+3 runs) | 6/6 exit 0, 5/5 handshake | anonymous, no operator | none published; see below |
| 2 | Open HTTP proxy, CONNECT to any port | 34.43.46.91:443 | none | banner + KEXINIT 672B, full ssh exit 0 x2, one 255 | 4.28s median full ssh | 2/3 full ssh, 5/5 handshake | anonymous | none published |
| 3 | Open HTTP proxy, CONNECT to any port | 107.167.18.122:443 | none | banner + KEXINIT 672B, full ssh exit 0 x3 | 4.86s median full ssh | 3/3 full ssh, 5/5 handshake | anonymous | none published |
| 4 | Open HTTP proxy, CONNECT to any port | 85.133.250.27:80 | none | banner + KEXINIT 672B, full ssh exit 0 x2 | 6.02-9.88s, 2/5 handshake | 2/5 | anonymous | none published |
| 5 | Open proxy on 80, same host as #1 | 47.239.140.6:80 / :443 | none | banner + KEXINIT observed in control runs | 2.3-11.5s, 1/5 | 1/5 | anonymous | none published |
| 6 | Open proxy on 80 | 51.170.133.249:80 | none | banner + KEXINIT observed | 0.85-8.6s, 1/5 | 1/5 | anonymous | none published |
| 7 | Open proxy on 80 | 47.107.107.24:80 | none | banner + KEXINIT observed | 6-17s, 3/5 | 3/5 | anonymous | none published |
| 8 | TURN RFC 6062 over TLS | turn.cloudflare.com:443 | Cloudflare TURN key | no-auth Allocate 0x0113 + NONCE+REALM; **does not implement RFC 6062** (documented + feature matrix "No") | n/a | n/a | corporate, status page, abuse contact | costs $0.05/GB unless used with Realtime SFU |
| 9 | TURN RFC 6062 over TLS | global.turn.twilio.com:443 | Twilio account | no-auth Allocate 0x0113 + REALM twilio.com, SOFTWARE `Coturn-4.6.1 'Gorst'`; auth Allocate unanswered | n/a | n/a | corporate | account required |
| 10 | TURN RFC 6062 over TLS | openrelay.metered.ca:443 | Metered account | no-auth Allocate 0x0113 + REALM metered.ca; auth Allocate unanswered | n/a | n/a | corporate | account required |
| 11 | TURN over TLS | 107.189.16.111:443 (turn.l.google.com) | Google TURN creds | no-auth Allocate 0x0113 + REALM turn.l.google.com; auth Allocate -> connection closed | n/a | n/a | corporate | Google terms; creds are shared/public-ish |
| 12 | Tailscale DERP | derp.tailscale.com:443 and region DERP | tailnet membership | **no help**, see below | n/a | n/a | corporate | n/a |
| 13 | Twingate | connector + relay, TCP 443 plus **30000-31000** | Twingate account | relay data path needs 30000-31000 and UDP/QUIC, both outside this sandbox's allowlist | n/a | n/a | corporate | account required; ToS bans unauthorized automated use |
| 14 | Cloudflare WARP / MASQUE | WARP client, MASQUE over HTTP/3 | account | out of scope for stdlib PoC: WARP needs its own client, MASQUE is HTTP/3, no stdlib HTTP/3, no pip | n/a | n/a | corporate | n/a |

Ranks 4 through 7 are marked measured-but-bad on purpose: a relay that
answers CONNECT 200 and then hangs is worse than one that refuses, because
you find out at KEX time. They are ranked above the unmeasured corporate
options only because they were measured at all.

## Class 3, answered honestly

**Tailscale DERP: no, it does not help here.** Proved, not assumed.
Tailscale's own docs (tailscale.com/kb/1232/derp-servers) say DERP's two
purposes are establishing connections between tailnet devices and
falling back to a relay between tailnet devices, and that a DERP region
carries WireGuard-encrypted packets addressed to a peer node in your
tailnet, chosen via a derpMap your control plane hands out. There is no
interface to ask a DERP server to open a TCP connection to an arbitrary
third-party host. DERP would help in sandssh "mode A", where you control
both ends and can join a tailnet, which is a different problem from
bridging an unjoinable target. For this target: no.

**Cloudflare TURN: reachable, credentialed, and the wrong protocol.**
turn.cloudflare.com:443 answers a no-auth TCP Allocate with a correct 401
carrying NONCE and REALM `turn.cloudflare.com`, over TLS 1.3, 116 bytes.
The credential minting path exists and is current
(`POST https://rtc.live.cloudflare.com/v1/turn/keys/$TURN_KEY_ID/credentials/generate-ice-servers`,
`Authorization: Bearer $TURN_KEY_API_TOKEN`, ttl up to 86400), and needs a
TURN key you create in the dashboard or API. But the same doc set's FAQ
says verbatim: "Realtime does not implement RFC6062 and will not respect
REQUESTED-TRANSPORT STUN attribute", and its feature matrix lists "TCP
relaying TURN extension | No | RFC 6062". So a valid credential buys an
allocation that cannot be TCP. Cloudflare also states the TURN service is
free only when used together with the Realtime SFU, otherwise $0.05 per
real-time GB outbound. Prompt hypothesis confirmed and then killed by the
protocol: this is not a missing-credentials problem.

**Twingate: reachable docs, blocked by the same wall as everything else.**
The `docs/reference/relays` path 404s in both variants, as the task said.
Current docs are at twingate.com/docs. Endpoint requirements, verbatim
from /docs/endpoint-requirements: outbound TCP 443 for the controller and
relay, outbound TCP 30000-31000 to Relay infrastructure when peer-to-peer
is unavailable, and outbound UDP plus QUIC for HTTP/3. This sandbox
permits CONNECT to 80/443/8443 only and has no usable UDP, so Twingate's
relay data path cannot be reached. An account is required regardless
("Try for Free" is gated on signup). Not viable from here.

**WARP and MASQUE: out of scope, stated plainly.** WARP is a consumer VPN
with its own client binary and needs a WireGuard implementation this box
does not have. MASQUE is HTTP/3, and CPython's stdlib has no HTTP/3 and
no QUIC; with no pip and no apt there is no way to add one. A stdlib PoC
cannot do this. I am not claiming it is impossible, only that it is out of
reach of this toolchain, and that "no stdlib HTTP/3" is the binding
constraint, not the network.

## Gateway policy, not transport, is what blocks the free tier

Worth separating from the relay question. Through the working relays the
Railway gateway's own policy is what refuses anonymous use:

    {"status":"refused","human_signup_url":"https://railway.com/ssh-signup?code=...",
     "description":"Anonymous visitors are limited. Sign up to keep building."}

`ssh` exit code 13 on a refused key, exit 0 once quota opened for a fresh
key at 16:56Z. Same relay, same key, minutes apart: exit 13 at 16:33Z,
exit 0 at 16:56Z. So the exit code reflects Railway's anonymous quota
opening and closing over minutes, not relay quality. Anything that reads
exit 13 as "the relay is broken" is misreading it.

## Sandbox defect found and worked around

`ssh`, `ssh-keygen` and `scp` all exit 255 with `No user exists for uid 0`
before doing anything, because this cage has no `/etc/passwd` and `/etc` is
not writable (`/etc` is on a read-only zfs dataset; uid 0 is a name, not a
kernel fact, and glibc refuses). `chroot` is also denied
(`Operation not permitted`), so the repo's other workaround does not
apply. The working fix is the repo's own `shims/fakepwd.c` built with
`gcc -shared -fPIC -O2 -o fakepwd.so fakepwd.c` and preloaded:

    LD_PRELOAD=/tmp/fakepwd.so ssh -V    # OpenSSH_10.5p1, OpenSSL 3.6.4

Every ssh measurement in this section was taken with that shim. Without it
no ssh exit code can be obtained in this cage at all, which is worth
knowing before anyone concludes the chain is untestable here.

## Terms of service and lawful-use note

Read, not assumed:

- TheSpeedX/PROXY-List, the largest source, states in its own README:
  "I collected them from the Internet for easy access. Remember, I'm not in
  charge of these proxies." There is no operator, no terms, no abuse
  contact, and no published permission for this use. Ranks 1 through 7 sit
  here.
- Whether using an unauthenticated open proxy without authorisation is
  lawful depends entirely on where the relay sits and what it is used for.
  I am not going to call it blanket-legal or blanket-illegal. What is
  measured: the SSH session is end-to-end encrypted, so the relay observes
  ciphertext, timing and size, and can at worst deny service. That is a
  fact about the traffic, not a legal opinion, and the legal question is
  genuinely open on this evidence. Treat these relays as untrusted
  infrastructure and never route anything through them that would be
  damaging if observed.
- Cloudflare: TURN is $0.05/real-time GB outbound unless paired with a
  Realtime SFU tenant. WARP and MASQUE are covered by Cloudflare's
  self-serve subscription agreement.
- Twingate: Customer Agreement v2024-04-22, "Try for Free" is account
  gated, and the agreement prohibits using "any method unauthorized by
  Twingate ... to extract or scrape data from the Services" and
  introducing "unauthorized software or automated agents or scripts".
- Tailscale: DERP servers are for tailnet members; using one outside a
  tailnet is not something their docs offer.

## What I could not verify, and what would settle it

1. Whether any of the three major public TURN services would complete an
   authenticated Allocate from a network that is not this cage. All three
   ignored the authenticated request, and a UDP-allocation control with
   the same credentials also timed out, so I could not tell "no RFC 6062"
   from "auth path blocked from here". Settled by: one authenticated
   Allocate from an unproxied host, with a real credential set.
2. Whether Cloudflare issues TURN credentials on a genuinely free tier with
   no Realtime SFU tenant. Docs say the service is free only alongside the
   SFU, otherwise metered. Settled by: minting a TURN key on a free
   account and reading the billing page. Even if it succeeds, RFC 6062 is
   documented as unsupported, so this does not change the ranking.
3. Whether Twingate or MASQUE would work given egress that allows UDP and
   TCP 30000-31000. Settled by: running the Twingate connector and a MASQUE
   client from a host with unproxied egress. Out of reach of this sandbox,
   which has no usable UDP by construction.
4. Throughput of the open-proxy path as a sustained rate. The 2.75s for
   2 MiB scp is a single upload measurement, not a saturating figure. A
   read-based throughput probe I wrote was wrong: after KEXINIT the SSH
   server sends nothing until the client speaks, so it always timed out.
   Settled by: `dd` on the VM with a large file over several runs.
5. Whether the current relay set survives the next day. 52.25.133.43:443
   died within three hours of being the best relay in the earlier run.
   Assume every row in the table is stale by morning. Settled by:
   re-running `find_relays.py` against a freshly pulled list.

## Reproduction

    git clone https://github.com/talaria0101/sandssh
    cd sandssh/bridge/railway
    python3 find_relays.py /path/to/fresh/proxy/list.txt 0 200   # 22 workers
    RELAYS=165.22.103.5:443 LD_PRELOAD=./fakepwd.so \
      ssh -o ProxyCommand="python3 $(pwd)/chain.py" -o ConnectTimeout=12 \
          -o BatchMode=yes -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -i your_key railway.new 'uname -a'
