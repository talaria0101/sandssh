# sandssh

**This tree is now the compatibility half of podbox's ssh transport.** The
transport itself lives in podbox, as `podbox remote ssh` and the standalone
`podssh`. This repository is kept, for now, for three things and no others.

## What is still here, and why

| path | why it is still here |
| --- | --- |
| `bin/sandssh` | the interop client. `podbox`'s `crates/podbox-ssh/tests/e2e.sh` runs this tree's own client against podssh's relay and server, unchanged, to prove podssh is a replacement and not a fork. |
| `relay/sandssh-relay.py` | the interop relay, and the same proof in the other direction. |
| `shims/fakepwd.c` | the passwd shim for a cage with no `/etc/passwd`. podbox's builder compiles this; the reference has to live somewhere. |
| `shims/fakepty.c` | the isatty/termios interposer for a cage with no pty. Still the only one. |
| `patches/dropbear-*.patch` | the two dropbear changes a seccomp-filtered cage needs. `dropbear-setgroups` is the one upstream keeps moving, so podbox re-applies it by hand. |
| `research/RELAY-BENCHMARKS.md` | the measured relay table podbox's catalog cites. |
| `CLEANUP.md` | what was removed on 2026-09-27 and what replaced each thing. |

## What is gone, and what replaced it

Everything else. The Cloudflare Worker relay and its client, the open-proxy
scanner, the GitHub control channel, the start/install scripts, the `ssh`
and `getent` wrapper scripts, and the tailnet patches are all either
superseded by podbox or answered by a better relay. `CLEANUP.md` names a
successor for every one, because a file deleted with no successor is a loss
dressed as tidying.

Every removal is in this repository's history, and the history is the record
of what was measured.

## The one thing to know about the shims

Both are `LD_PRELOAD` and **neither can reach a statically linked binary**.
That is not a caveat, it is the measurement that shaped podbox's ssh server:
a statically linked dropbear carries its own libc, so it cannot see that
`root` exists and logs `Login attempt for nonexistent user` for a user that
is there. podbox's builder therefore produces a DYNAMICALLY linked dropbear.
See `docs/decisions/ssh-server-in-a-cage.md` in podbox.

## Licence

See `LICENSE`. The patches are against dropbear, which is MIT-licensed, and
carry no dropbear code.
