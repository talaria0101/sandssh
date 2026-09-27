---
name: sealed-sandbox
description: Operate and diagnose a sealed agent sandbox — no bind, no pty, no /etc/passwd, egress only through a proxy, and mounts that refuse exec. Use when a cage denies bind or chroot, when an ssh server cannot start, when a login is refused with publickey, or when a program needs a terminal that does not exist.
---

# Working inside a sealed sandbox

A sealed cage typically has: no `bind(2)`, no `/dev/ptmx`, no `/etc/passwd`, no
`/var`, no UDP, possibly no resolver, and an egress that only reaches a proxy or
a whitelisted rendezvous. Each has a named workaround here.

## First, measure

```sh
sandhome space --probe   # which roots run a binary
sandhome report          # pty, passwd, libc, privilege, provider
```

`report` reads the machine. Do not infer a capability from a package list.

## No bind

Both ends must dial out. `sandssh` (`bin/sandssh`) carries ssh over a rendezvous
relay the peers dial; nothing listens. `relay/sandssh-relay.py` is the reference
relay. See `research/RELAY-BENCHMARKS.md` for the measured latency and failure
taxonomy — a public relay is perishable, so re-measure rather than trust it.

## No pty

Use `errandsh` (`skills/errandsh/SKILL.md`). For a program that needs
`isatty(2)` to be true, build and load the interposer:

```sh
sandhome shims
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"
```

## No /etc/passwd

`fakepwd.so` answers `getpwnam`/`getpwuid` from `$SANDSSH_PASSWD`. `env.sh`
exports it when `SANDHOME_SHIMS=1`. Add login names with
`SANDHOME_PASSWD_USERS=agent`. An ssh server refuses an unknown account with
`Permission denied (publickey)`, which reads as a key problem and is not one.

> **Build the server dynamically.** A statically linked binary carries its own
> libc, so `LD_PRELOAD` cannot reach it. A static `dropbear` also cannot see a
> synthetic passwd entry and logs `Login attempt for nonexistent user` for a user
> that is there. This is the measurement that shaped the podbox ssh server, and
> `shims/fakepwd.c` is its reference.

## No chroot, and sshd will not start

`sshd -i -t` exiting 0 is not evidence that `sshd -i` runs. A modern OpenSSH
needs a privilege-separation user and a chroot directory that a cage denies:

1. `sshd -i -t -f <config>` exits 0
2. `sshd -i` → `Privilege separation user nobody does not exist`
3. with a `nobody` entry → `Missing privilege separation directory: /var/chroot/ssh`
4. `ChrootDirectory` moved → no effect; a different hardcoded path
5. `UsePrivilegeSeparation no` is deprecated and ignored since OpenSSH 8.4

No configuration fixes it. Use a dynamically built `dropbear` that tolerates a
denied `setgroups(2)`; `patches/dropbear-setgroups-tolerance.patch` is the change.

## Mounts

If a toolchain will not run, read `sandhome space --probe`. `docs/decisions/exec-split.md`
explains why data and executables may be on different roots, and why a shared
object is symlinked while a binary is copied.
