# AGENTS.md

**An agent working in this repository should read this and nothing else.** It is
self-contained: what this tree is, what it is not, how to build and test it, and
the traps with the measurement that establishes each.

## What this is

`sandssh` is the client that reaches a sealed agent sandbox with ssh, over
whatever the network still allows, plus a rendezvous relay that both ends dial
out to.

A sealed cage typically has no `bind(2)`, no `/dev/ptmx`, no `/etc/passwd`, no
`/var`, no UDP, and an egress that reaches only a proxy or a whitelisted
rendezvous. `sandssh` works under exactly those conditions: **nothing listens in
the cage and nothing needs to.** The ssh session between the real peers is end
to end encrypted, so the relay carries ciphertext and nothing else.

## STATUS: this is the python transport. A C one exists and is more capable.

| what | where |
| --- | --- |
| **this tree** | the python client, the python rendezvous relay, the two `LD_PRELOAD` shims, the dropbear patches, the relay measurements | 
| `dropssh` | <https://github.com/talaria0101/dropssh> — the same job in C on patched dropbear, single static binary, with a rendezvous **and** a forward relay client |
| `sandhome` | <https://github.com/talaria0101/sandhome> — the sandbox home: the shims, `errandsh` for a pty-less session, and a bootstrap that does this automatically |

Nothing here depends on sandhome and nothing in sandhome depends on here.

**Which to use.** If you want the simplest thing that works, use **dropssh**:
it is one static binary with the shims built in, and its `AGENTS.md` is the
entry point. This tree is still the reference for the shape, the deployment and
the measurements, and it is what `podbox`'s interop tests exercise.

## Reading order

1. This file.
2. [`README.md`](README.md) — usage, the deployment, the shims, the patches.
3. [`relay/DEPLOY.md`](relay/DEPLOY.md) — systemd, a plain process, a unix
   socket for a cage that cannot `bind`, and the TLS terminators.
4. [`research/RELAY-BENCHMARKS.md`](research/RELAY-BENCHMARKS.md) — the measured
   relay table, which is a record of measurements rather than instructions.

## Using it

```sh
# from your machine
sandssh connect --relay wss://relay.example:8443 --name mybox

# in the cage, to serve
sandssh serve --relay wss://relay.example:8443 --name mybox
```

`sandssh probe` maps every route the network allows and recommends one. Run it
first in an unfamiliar environment; it is the difference between a five-minute
diagnosis and an afternoon.

## Repository layout

```
bin/sandssh              the client. Verbs: probe, serve, connect, selftest,
                         config, and the GitHub control channel (gh-listen,
                         gh-send, gh-shell). There is NO client-side relay
                         verb: the relay is relay/sandssh-relay.py, run on
                         its own.
relay/sandssh-relay.py   the rendezvous relay, stdlib python, no dependencies
relay/DEPLOY.md          how to stand one up
relay/sandssh-relay.service  the systemd unit DEPLOY.md installs
shims/fakepwd.c          passwd database for a cage with no /etc/passwd
shims/fakepty.c          isatty/termios interposer for a cage with no pty
patches/dropbear-*.patch the dropbear changes a seccomp-filtered cage needs
research/                measured relay tables
```

The `gh-*` verbs are a control channel over a **private GitHub repository**, for
a cage whose only egress is `github.com`: the node polls for commands and the
operator writes them. It is the awkward fallback for when even a whitelisted
relay is not reachable, and it is why `probe` exists — run it before choosing.

There is no build step. The client and the relay are python 3, stdlib only; the
shims are two C files; the patches are diffs.

## Testing

```sh
python3 bin/sandssh selftest     # framing, redaction, envelope, no network
```

`selftest` covers websocket framing over a socketpair, the credential redaction
path and the HMAC envelope. It needs no network and no relay, so it is the
thing to run first after any change.

There is no test for the shims in this tree; `errandsh`'s tests moved to
sandhome with `errandsh` itself.

## Conventions

* **stdlib python only.** A cage rarely has `pip`, and a tool whose runtime is a
  coincidence is a tool that stops working. `selftest` exists partly to keep it
  honest.
* No third-party packages, anywhere, including the scripts.
* Comments explain **why** and carry the measurement. A comment restating the
  line is noise; a comment saying why the obvious thing is wrong is the only
  documentation that survives the next edit.
* `⛔` marks a trap or a measured failure, used consistently so a reader can
  scan for them.
* Never commit a credential. A relay key is a credential; `connect --auth` and
  `SANDSSH_RELAY_KEY` carry it at runtime and nothing persists it.
* The relay carries **ciphertext**. Do not add anything to it that needs to read
  a session, and do not log a session's bytes.

## Traps, so you do not rediscover them

* **Neither shim can reach a statically linked binary.** A static binary carries
  its own libc, so there is nothing to interpose into. Build the ssh server
  **dynamically** or `LD_PRELOAD` is silently inert, and the server logs
  `Login attempt for nonexistent user` for a user that is there. This is a
  measurement, not a caveat.
* **`fakepwd.so` reads `$SANDHOME_PASSWD` first** and still answers to the older
  `$SANDSSH_PASSWD`, so a machine configured against the previous name is not
  broken by the rename. With neither set it falls back to
  `/etc/sandhome/passwd`, and with nothing readable it answers a single `root`
  entry whose shell is `/bin/bash` — which a cage often lacks. Name a shell that
  exists in your passwd file.
* **A cage cannot `bind(2)`, but the relay runs on the operator's machine,**
  which usually can. The unix-socket form exists for a **relay** run inside a
  bindless cage, and it is spelled differently on each side, which is the trap:
  * relay: `--listen /unix/tmp/relay.sock`, and with `--transport ws`,
    `--listen ws+unix:///tmp/relay.sock`
  * client: `--relay unix:///tmp/relay.sock`, **three** slashes, because the
    target is an absolute path

  Two slashes on the client and it treats the rest as a host, which is a
  confusing error rather than a clear one.
* **A cage has no resolver.** The relay URL is passed to the client and the
  proxy resolves it; a literal address is not always available. `probe` reports
  which routes exist.
* **`dropbear-setgroups-tolerance.patch` is the one upstream keeps moving.** It
  is a seccomp-filtered cage denying `setgroups(2)`, which makes `initgroups()`
  always fail and every login die with `Error changing user group`. If a
  rebase makes the patch stop applying, that is why, and the fix is to re-apply
  it by hand rather than to drop it.
* **A rendezvous is not a forward proxy.** The relay pairs two peers that both
  dial it and splices their bytes. It cannot reach a target on a client's
  behalf. `dropssh` implements both, and the two differ in exactly which hop is
  last.

## Related work

* <https://github.com/talaria0101/dropssh> — the C transport, and the one to
  reach for first.
* <https://github.com/talaria0101/sandhome> — the shims, `errandsh`, the
  bootstrap.
* <https://github.com/Azathothas/podbox/pull/67> — the Rust `podssh`, whose
  interop tests exercise this tree's client and relay unchanged.
