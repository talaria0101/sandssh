# Handoff: test the Cloudflare Worker SSH relay once it is deployed

You (a later Talaria session) are picking this up. Read this whole file
before doing anything. It is written for a session that has not seen the
design discussion.

## Situation

Ajam designed, and I built, a serverless SSH relay so a constrained
sandbox can reach a TCP-only SSH target (`railway.new:22`) with no
infrastructure to manage. The mechanism:

    ssh -> ws_ssh_relay.py (ProxyCommand)
      -> sandbox egress HTTP CONNECT proxy (allowed 443 only)
      -> your deployed Cloudflare Worker (ssh_relay_worker.js) on *.workers.dev
      -> Worker runtime connect() -> railway.new:22

The Worker is a plain Cloudflare Worker. It uses the runtime `connect()`
API (plain outbound TCP; the docs name SSH as supported) to dial the
target, and splices bytes between that TCP socket and a WebSocket on its
own edge. No VPC, no Mesh, no Tunnel, no TURN server, no origin box.

Ajam will run `npx wrangler deploy` on their machine and return with the
deployed URL. Your job is to test the deployed Worker end to end from the
sandbox and report measured results.

## Where everything is

Repo: https://github.com/talaria0101/sandssh, directory `bridge/railway/`.
Clone if not present, then read these in order:

- `WORKER_RELAY.md` - the design, deploy steps, and what is/isn't verified.
- `ssh_relay_worker.js` - the Worker. Target pinned in `CFG` at the top.
- `wrangler.toml` - deploy config.
- `ws_ssh_relay.py` - the client ProxyCommand. Stdlib RFC 6455.
- `proxycommand_worker.md` - usage and why this beats the open-proxy chain.
- `BENCHMARKS.md` - the measured open-proxy baseline you will compare against.
- `ws101.py` - WebSocket reachability probe (step 2 of the test plan).
  Prints the first status line from the Worker through the sandbox egress.
- `chain.py` - the open-proxy ProxyCommand (control path, step 5). Reads the
  egress proxy from `$HTTPS_PROXY`; pin a relay with `RELAYS=host:port`.

## What you need from Ajam

Just the deployed URL, e.g. `https://ssh-relay.<name>.workers.dev`. If
they changed `CFG.host`/`CFG.port`/`CFG.banner`, they must say so; the
banner in `CFG` must match the target or the Worker refuses to relay.

## Environment facts you must not rediscover the hard way

- Sandbox: Linux, uid 0, NO `/etc/passwd`, `/etc` not writable, no bind
  (socket.bind raises PermissionError), no direct TCP, no ICMP, no usable
  UDP. All egress is an HTTP CONNECT proxy whose address is in
  `$HTTPS_PROXY`; THE PORT CHANGES EVERY SESSION. Never hardcode it. Read
  it from the env. Do not reuse any port from an earlier session.
- Because `/etc/passwd` is absent, `ssh`, `ssh-keygen`, and `scp` all exit
  255 with `No user exists for uid 0` before doing anything. Use the repo's
  prebuilt shim on every ssh/ssh-keygen/scp call:
      LD_PRELOAD=/workspace/sandssh/shims/fakepwd.so
  (If the clone is elsewhere, use its `shims/fakepwd.so`. If it is missing,
  build it: `gcc -shared -fPIC -O2 -o fakepwd.so shims/fakepwd.c`.)
- `workers.dev:443` and `trycloudflare.com:443` were confirmed reachable
  from the sandbox egress (HTTP/1.1 200 Connection established) in an
  earlier session. Re-confirm cheaply if the Worker test fails at connect.
- `chain.py` never hardcodes the proxy port; it reads env. Good.
- No direct DNS in-process. `socket.gethostbyname` fails. If you need to
  resolve a name, do it through the egress proxy with a DoH JSON request
  (see the pattern in the earlier session, or just use the hostname and let
  the proxy/Worker resolve it).

## Test plan, in order. Do not skip the controls.

Every command must have an explicit timeout. Read exit codes from the
process that produced them, never through a pipe.

0. Record the date and time first:

       date -u

   Put the real timestamp in the report. Do not write a date you did not
   read from `date -u` on the machine you ran on.

1. Health check the deployed Worker (no key, no ssh needed). Confirm HTTP
   code AND that the body is the health JSON, not a CF error page:

       curl -s -m 25 -o /tmp/whealth -w "%{http_code}\n" "<WORKER_URL>"
       cat /tmp/whealth

   Expect 200 and `{"ok":true,"target":"railway.new:22"}`. A 404/530 here
   means the Worker is not deployed under that name, not that the design is
   broken.

2. Confirm the WebSocket upgrade returns 101 through the sandbox egress
   (this is the same first hop `ws_ssh_relay.py` uses). There is a ready
   probe in this directory, `ws101.py`:

       python3 /workspace/sandssh/bridge/railway/ws101.py <worker-host> 443

   It prints the first status line. Interpret it:
   - `HTTP/1.1 101 ...`  the WS hop is proven; the target dial is the only
     remaining unknown.
   - `HTTP/1.1 301/404/426` you reached the origin but it did not upgrade.
     For a real Worker a 426 means you hit the health path instead of the
     WS path, or the Worker name is wrong; a 404 means the route is not
     deployed under that name.
   - `egress refused` the sandbox egress allowlist does not include that
     host. Note: `workers.dev` itself is not the deployed name; use the
     exact `<name>.<you>.workers.dev` or custom domain Ajam gives you.
   - `timeout` / `FAIL` the tunnel or TLS failed; check `$HTTPS_PROXY`.

   If this returns 101, the edge hop is proven.

3. THE MAIN TEST. Full ssh through the Worker. Use a throwaway key, never
   a committed key. Generate it, run, then delete it:

       LD_PRELOAD=/workspace/sandssh/shims/fakepwd.so ssh-keygen -t ed25519 \
         -N '' -f /tmp/worker_probe -C worker-probe
       RELAYS_UNUSED=1 timeout 90 env LD_PRELOAD=/workspace/sandssh/shims/fakepwd.so \
         ssh -o ProxyCommand="python3 /workspace/sandssh/bridge/railway/ws_ssh_relay.py <WORKER_URL>" \
             -o ConnectTimeout=12 -o BatchMode=yes \
             -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o IdentitiesOnly=yes -i /tmp/worker_probe \
             railway.new 'uname -a; echo WORKER_RELAY_OK'
       echo "ssh exit=$?"
       rm -f /tmp/worker_probe /tmp/worker_probe.pub

   Adjust the path to `ws_ssh_relay.py` to wherever you cloned the repo.

4. Interpret the exit code carefully, because two different things can
   fail and only one of them is the Worker:

   - exit 0 and output containing your command's result: PASS, full success.
   - exit 13 with JSON `{"status":"refused", ... "Anonymous visitors are
     limited"}`: the Worker relayed bytes correctly and Railway's gateway
     refused the anonymous session. This is a PASS for the relay and a
     statement about Railway's anonymous quota, NOT a Worker bug. The
     gateway's own log shows `exit status 13` after a successful SSH
     auth+channel, which is how you tell it apart from a transport failure.
   - exit 255 and the client stderr shows the Worker path never opened
     (no "websocket open, splicing to target" line from
     `ws_ssh_relay.py`): the WebSocket or the edge dial failed. That IS a
     Worker/client problem. Capture the `ws_ssh_relay.py` stderr lines.
   - ssh hangs: you missed a timeout. Re-run with `timeout 90` and
     `ConnectTimeout 12`.

5. Control run, so the result means something: same exact command through
   the open-proxy chain on a currently-good relay. Read the current relay
   list from `chain.py`; pin one with `RELAYS=`. This proves the target
   itself is reachable right now, independent of the Worker:

       RELAYS=165.22.103.5:443 timeout 90 env LD_PRELOAD=/workspace/sandssh/shims/fakepwd.so \
         ssh -o ProxyCommand="python3 /workspace/sandssh/bridge/railway/chain.py" \
             -o ConnectTimeout=12 -o BatchMode=yes \
             -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o IdentitiesOnly=yes -i /tmp/worker_probe railway.new 'uname -a'
       echo "control exit=$?"

   If the control also fails, the target or Railway's quota is the issue,
   not the Worker. Note: in the last session (17:25Z) Railway's anonymous
   quota was CLOSED, so the control returned exit 13 while all three relays
   still passed banner+KEXINIT. Expect that.

6. If the Worker path works (exit 0, or exit 13 proving a relayed
   session), also measure it the way BENCHMARKS.md measures, so the two
   paths can be compared: run the same command 3 times, record wall clock
   per run, and report the median. Use `date +%s.%N` around each run and
   compute the delta, do not eyeball it.

7. If the Worker path FAILS at the edge dial (step 3 gives 255 with the
   websocket-open line but the target banner never arrives), the likely
   cause is the banner guard: `CFG.banner` in `ssh_relay_worker.js` must
   equal the target's SSH banner (`SSH-2.0-Go` for railway.new). A mismatch
   makes the Worker throw `wrong target banner` and close. Ask Ajam to
   confirm `CFG`, or fix it and have them redeploy.

## Deliverable

- A short markdown report in `bridge/railway/WORKER_TEST_<date>.md` (date
  from the `date -u` you actually ran) containing:
  - the `date -u` start and end of the test window,
  - the sandbox kernel line from `uname -a`,
  - step 1 health result (HTTP code + body),
  - step 2 WS 101 result,
  - step 3 main result: the ssh exit code, the command's stdout, and the
    exact `ws_ssh_relay.py` stderr, labelled as measured,
  - step 5 control result (open-proxy exit code and banner),
  - median wall clock for 3 runs if it worked,
  - a one-line verdict: does the Worker relay carry SSH to railway.new:22
    from this sandbox, yes or no, with the evidence line that decides it,
  - anything you could not verify and what would settle it.
- Do NOT commit the throwaway key. `.gitignore` already excludes `keys/`
  and `*.private.json`; put any key under `keys/` or `/tmp` and delete it.
- Do not push or open a PR unless Ajam asks in the thread.

## Things that are already known, do not re-litigate

- A plain Worker `connect()` CAN reach a public TCP target. No connector,
  VPC, or Mesh is involved. This is the whole point of the design.
- Cloudflare Realtime's managed TURN does NOT implement RFC 6062, so it is
  not usable as a TCP relay. Do not revisit it.
- `ws_ssh_relay.py`'s RFC 6455 codec is tested: 1..200,000 bytes
  round-trip byte-identical across the 126 and 65536 frame boundaries, with
  correct half-close teardown, against a stdlib unix-socket WebSocket
  server. You do not need to re-test the codec; test the deployed Worker.
- pwnat, Tailscale DERP, Twingate, and sandssh mode B were each assessed
  and none reach a public TCP target from this sandbox. Details are in
  `BENCHMARKS.md`. Do not re-research them.
