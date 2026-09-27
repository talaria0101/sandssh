# Cleanup plan, 2026-09-27

podbox now carries the ssh transport in `crates/podbox-ssh`. This tree is
kept, for now, for two reasons only:

1. **interop.** `crates/podbox-ssh/tests/e2e.sh` runs three cases against
   this tree unchanged: its client against podssh's relay and server, its
   relay under podssh on both ends, and its server under podssh's relay and
   client. A protocol that only talks to itself is a fork, not a
   replacement, and those three cases are what makes that a measurement.
2. **the shims and the patches.** podssh re-applies
   `dropbear-setgroups-tolerance.patch` by hand because upstream moved the
   code, and the passwd shim is the reference for the one podbox builds.

Everything else here is either superseded, or a record of a measurement that
is now cited from podbox's own tree.

## KEEP, and why

| path | why |
| --- | --- |
| `bin/sandssh` | the interop client. `e2e.sh` runs it. |
| `relay/sandssh-relay.py` | the interop relay. `e2e.sh` runs it. |
| `relay/DEPLOY.md` | how to stand that relay up. |
| `relay/sandssh-relay.service` | the unit file `DEPLOY.md` installs. |
| `shims/fakepwd.c` | the reference passwd shim. podbox's builder compiles this. |
| `shims/fakepty.c` | still the only isatty/termios interposer for a cage with no pty. |
| `patches/dropbear-setgroups-tolerance.patch` | the setgroups change, upstream-movable. |
| `patches/dropbear-inetd-pipe-tolerance.patch` | the ENOTSOCK change, for a pipe-carried server. |
| `bridge/railway/BENCHMARKS.md` | the measured relay table podbox's catalog cites. |
| `LICENSE` | needed by anything derived from it. |

## REWRITE, because a better one is coming

| path | what replaces it |
| --- | --- |
| `shell/errandsh` | a pure POSIX sh line discipline, written in this cleanup. |

## REMOVE, superseded by podbox

| path | superseded by |
| --- | --- |
| `bridge/railway/chain.py` | `crates/podbox-ssh/src/http.rs` and `chain.rs` |
| `bridge/railway/find_relays.py` | `experiments/401-podssh-relays.sh` in podbox |
| `bridge/railway/ws_ssh_relay.py` | `crates/podbox-ssh/src/transport/ws.rs` |
| `bridge/railway/ws101.py`, `ws_probe.py` | the same, and the relay it probes is superseded |
| `bridge/railway/turn_tls_probe.py` | `crates/podbox-ssh/src/turn.rs` is not wired in; the probe's FINDINGS are what podbox's catalog records, and the script is not needed to re-take them |
| `bridge/railway/ssh_relay_worker.js`, `wrangler.toml` | the ajam relay replaces the Worker |
| `bridge/railway/*.md` except BENCHMARKS.md | podbox's `docs/decisions/` carries the findings |
| `bin/ssh`, `bin/getent` | podbox installs names with `system install-names`, and the passwd shim is compiled into the builder |
| `bin/ssh` wrapper specifically | it is a wrapper SCRIPT, which T-1001 rules out: a wrapper is a second artefact and it breaks the memfd rung. The shim is an `LD_PRELOAD`, not a wrapper. |
| `start.sh`, `install.sh` | podbox's builder, `scripts/build-*.sh` |
| `tests/test_gh_*.sh` | the github control channel is not in podbox; if it returns it returns with a test |
| `keys-example/tailcat-key.example.json` | tailcat is not a podssh transport |
| `patches/tailcat-pty-fallback.patch` | same |
| `patches/tailscaled-setgroups-tolerance.patch` | tailscaled is not a podssh transport |
| `shims/*.so` | BUILD OUTPUT. Never committed; built by the builder. |
| `overlay/etc/*` | podbox carries its own overlay |

Every one of these is recoverable from git history, and the history is the
record of what was measured.

## The two rules this cleanup follows

1. **Nothing is deleted before its evidence is committed.** The measurements
   move into podbox's `docs/decisions/` and `experiments/results/`, or stay
   in this tree's history, before the file goes.
2. **A removal says what replaced it.** A file deleted with no successor is a
   loss dressed as tidying, and a later session cannot tell a deliberate
   removal from an accident.
