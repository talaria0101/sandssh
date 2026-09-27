# sandssh

Reach a sealed agent sandbox with ssh, over whatever the network still allows.

A sealed cage typically has no `bind(2)`, no `/dev/ptmx`, no `/etc/passwd`, no
`/var`, no UDP, and an egress that reaches only a proxy or a whitelisted
rendezvous. `sandssh` is the client that works under exactly those conditions,
and `sandssh-relay` is the rendezvous both ends dial out to.

## The shape

```
  your machine                    the cage
 +--------------+                +--------------+
 |  sandssh     |                |  sshd        |
 |  connect     |                |  (dynamic)   |
 +------+-------+                +------^-------+
        |  both dial OUT                 |
        +----------> relay <-------------+
                    (pairs the two
                     connections,
                     splices bytes)
```

Nothing listens in the cage and nothing needs to. The ssh session between the
real peers is end to end encrypted, so the relay carries ciphertext and nothing
else: the simpler it is, the fewer ways it can stall.

## Use it

`sandssh probe` maps every route the network allows and recommends one. Then:

```sh
# from your machine
sandssh connect --relay wss://relay.example:8443 --name mybox

# in the cage, to serve
sandssh serve --relay wss://relay.example:8443 --name mybox
```

`--name` must be the same on both ends: it is what the relay pairs them by.
`--auth` is the shared secret; without one, anyone who knows the name may pair.
`--insecure` skips certificate verification, which is for a relay under test and
not for one in production.

| mode | transport | needs |
| --- | --- | --- |
| `B` relay | ssh over a rendezvous relay | nothing inbound in the cage |
| `A` tailnet | userspace tailscale plus tailcat | a control server and DERP reachable |
| `C` gh | a control channel over a private gist | egress to GitHub only; not interactive |

Full flags: `sandssh <subcommand> --help`. Subcommands are `probe`, `serve`,
`connect`, `gh-listen`, `gh-send`, `gh-shell`, `selftest` and `config`.

## Run the relay

The relay is one Python file with no dependency outside the standard library,
and so is the client. Neither needs a virtualenv.

```sh
python3 relay/sandssh-relay.py --listen :8443 --key <secret>
python3 relay/sandssh-relay.py --listen /tmp/relay.sock --key <secret>   # bindless test
python3 relay/sandssh-relay.py --listen :443 --key <secret> \
    --tls-cert fullchain.pem --tls-key privkey.pem                        # terminate TLS itself
```

`relay/DEPLOY.md` has the deployment: systemd, a plain process, a unix socket
for a cage that cannot bind, and the TLS terminators.

## The shims

A cage with no `/etc/passwd` makes sshd refuse to start, and a cage with no
`/dev/ptmx` makes an interactive session arrive with no echo. Both are
`LD_PRELOAD` interposers in `shims/`:

- **`fakepwd.c`** answers `getpwnam`/`getpwuid` from a synthetic passwd
  database, so an account that is in no database is still found.
- **`fakepty.c`** reports fds 0-2 as a terminal to a program that insists on
  one, so readline and echo work over a pipe.

```sh
gcc -shared -fPIC -O2 -o fakepwd.so shims/fakepwd.c
LD_PRELOAD=./fakepwd.so SANDHOME_PASSWD=/path/to/passwd sshd -i
```

`fakepwd.so` reads `$SANDHOME_PASSWD` first and still answers to the older
`$SANDSSH_PASSWD`, so a machine configured against the previous name is not
broken by the rename. With neither set it falls back to
`/etc/sandhome/passwd`; with nothing readable it answers a single `root` entry.

> **Neither shim can reach a statically linked binary.** A static binary carries
> its own libc, so there is nothing to interpose into. Build the ssh server
> **dynamically**, or `LD_PRELOAD` is silently inert and the server logs
> `Login attempt for nonexistent user` for a user that is there. This is a
> measurement, not a caveat.

For a sandbox home, a line discipline for a session with no pty, and a setup
that does all of this automatically, see `talaria0101/sandhome`. Nothing in
this repository depends on it and nothing in that one depends on this.

## The patches

A seccomp-filtered cage denies `setgroups(2)` and answers `ENOTSOCK` to
`socket(AF_INET, SOCK_STREAM)`. `patches/` carries both changes for dropbear:

- `dropbear-setgroups-tolerance.patch` - tolerate a denied `setgroups(2)`.
- `dropbear-inetd-pipe-tolerance.patch` - tolerate `ENOTSOCK` for a server
  carried over a pipe rather than a socket.

Both are small and both are applied at build time by whoever builds the server.
They are against dropbear, which is MIT-licensed, and carry no dropbear code.

## Research

`research/` holds measurements with the conditions attached to every number,
because a number without its conditions is folklore. The relay table in
`RELAY-BENCHMARKS.md` is dated 2026-09-26 and is **stale by construction**: a
shared public relay is perishable, and one of that day's best was dead within
three hours. Re-measure before relying on any row in it.

## Licence

See `LICENSE`.
