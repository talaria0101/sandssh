# sandssh

Seamless SSH into sealed AI-agent sandboxes: tailscale in userspace mode plus a
patched tailcat ssh server and a userspace line discipline, so you (or your
agent) can open a shell on a machine that has no pty, no `/etc/passwd`, and no
listening sockets.

Built and verified inside a hardened agent sandbox (seccomp + Landlock-style
path policy, chroot-only, `mknod` denied, `/dev/ptmx` absent, TCP bind
denied). Every workaround here was forced by a real denial.

```
 your laptop                          sealed agent sandbox
┌────────────┐   tailnet (WireGuard)  ┌──────────────────────────────┐
│ tailcat    ─┼───────────────────────►│ tailcat serve no-auth-ssh    │
│ ssh client │                        │   └─ errandsh (bash + REPL)  │
│ openssh    ─┼───────────────────────►│ tailscaled --ssh (exec only) │
└────────────┘                        │   └─ chroot at errand home   │
                                      └──────────────────────────────┘
```

## The constraints, and what answers them

| cage says | sandssh does |
|---|---|
| no `/dev/ptmx`, `mknod`/devpts denied → no kernel pty, ssh pty allocation fails | **tailcat patch**: sessions fall back to pipes when `pty.Open()` fails; **errandsh** provides echo, editing, history, signals in userspace |
| `/etc` read-only, no `/etc/passwd` → openssh/ssh-keygen refuse to run | **fakepwd.so** (`LD_PRELOAD`): synthetic passwd db, multi-user via `$SANDSSH_PASSWD` |
| `/proc` absent → tailscaled's ssh server dies lazily on `os.Executable()` | run tailscaled **chrooted** at the errand home with `proc/self/exe → /bin/tailscaled` |
| TCP bind denied → no sshd on :22 reachable from inside | tailscale's netstack serves ssh from userspace; **setgroups patch** tolerates seccomp's `setgroups(2)` denial when identity is unchanged |
| `/tmp` tiny tmpfs | state and logs live in `ts-state/` under the errand home |

## What you get

- `ssh root@<node-ip> "cmd"` — one-shot exec over tailscale-ssh, auth by
  tailnet identity (no keys to install).
- `tailcat ssh root@<tc-addr>` — interactive-ish shell (from Windows too:
  `tailcat.exe ssh root@<addr>`), running errandsh with prompt, history,
  tab completion and a real Ctrl-C.

## Quickstart (human)

Requires: a tailscale account + auth key, linux sandbox with egress allowed.

```sh
git clone https://github.com/talaria0101/sandssh.git
cd sandssh
./install.sh                          # fetches tailscale + tailcat, builds shims
TS_AUTHKEY=tskey-auth-... ./start.sh  # joins your tailnet as $SANDSSH_NODE_NAME
./start.sh status                     # note the node ipv4
./start.sh addr                       # e.g. 100.x.y.z
```

From any machine on the same tailnet:

```sh
ssh root@100.x.y.z "uname -a"         # exec, auth via tailnet identity
tailcat ssh root@<tc-addr-from-start> # interactive errandsh session
```

The `tc-addr` (a long `tcpGFw...` string) is printed by `start.sh` and lives in
`ts-state/tailcat.log`. The client binary for your laptop is on the
[tailcat releases page](https://github.com/tailscale/tailcat/releases)
(`tailcat.exe` works fine on Windows).

## Quickstart (agent)

Everything an orchestrator needs, no questions asked:

```sh
git clone --depth 1 https://github.com/talaria0101/sandssh.git /tmp/ss && cd /tmp/ss
./install.sh
TS_AUTHKEY="$TS_AUTHKEY" SANDSSH_NODE_NAME=my-agent ./start.sh
./start.sh addr   # report this back to your operator
```

Notes for agent authors:

- `install.sh` and `start.sh` are idempotent and restart-safe; `ts-state/`
  holds the node identity, so a restarted container rejoins without re-auth.
- Set `SANDSSH_NODE_NAME` per agent so the tailnet machine list stays readable.
- If outbound is proxied/filtered, `install.sh` honors standard `HTTPS_PROXY`
  vars (curl/wget do).
- Do not put `ts-state/` in an ephemeral dir; the node key is your identity.
- Everything runs as the agent's own uid. That is the point: the session is
  exactly as privileged as the agent, no more.

## Components

| path | what |
|---|---|
| `install.sh` | fetch + build + scaffold, idempotent |
| `start.sh` | tailscaled (chrooted) + `tailscale up --ssh` + tailcat serve |
| `shell/errandsh` | userspace line discipline: one long-lived bash, echo/line editing, history (up/down), tab completion (commands + paths), Ctrl-U/Ctrl-W, Ctrl-L, real Ctrl-C to the job's process group, persistent cwd/env, `-c` passthrough for exec channels |
| `shims/fakepwd.c` | `getpwuid/getpwnam/getspnam` (+`_r`) interposer; sources from `$SANDSSH_PASSWD`, `/etc/sandssh/passwd`, or a built-in root default |
| `shims/fakepty.c` | isatty/termios interposer for fds 0-2 (optional; errandsh supersedes it) |
| `patches/tailcat-pty-fallback.patch` | pty sessions degrade to pipes when the host has no pty; interactive requests run `$SHELL -li` so the preload yields editing; `LD_PRELOAD` passes through to the session |
| `patches/tailscaled-setgroups-tolerance.patch` | tailscaled ssh: tolerate `setgroups(2)` failure when not actually dropping identity (seccomp forbids it) |
| `overlay/etc/` | the tiny passwd/group/nsswitch/resolv the chroot sees |
| `bin/ssh`, `bin/getent` | wrappers: fakepwd preload; pure-bash getent for the chroot |
| `keys-example/` | shape of a tailcat key file (the real one is generated on first `tailcat serve`) |

## Building the patched binaries

```sh
# tailscale (v1.102.4), static, no cgo
git clone https://github.com/tailscale/tailscale --depth 1 -b v1.102.4
cd tailscale && git apply /path/to/sandssh/patches/tailscaled-setgroups-tolerance.patch
CGO_ENABLED=0 ./build_dist.sh tailscaled

# tailcat
git clone https://github.com/tailscale/tailcat --depth 1
cd tailcat && git apply /path/to/sandssh/patches/tailcat-pty-fallback.patch
go build -o tailcat .
```

## Security model

- `tailcat serve no-auth-ssh` accepts any client that can route to the tailcat
  address over the tailnet. "No auth" here means **transport identity is the
  auth**: being on the tailnet is the credential. Treat tailnet membership
  accordingly.
- The tailcat private key in `~/.config/tailcat/keys/` **is** the node
  identity. Backup = anyone with the file is the node. Keep it out of images.
- Sessions run with the agent's own uid inside the same cage; the stack adds
  remote reach, not privilege.
- The tailscale auth key (`tskey-auth-...`) is single-use-ish and scoped;
  prefer ephemeral keys for short-lived agents.

## Known limits

- No true kernel pty, so no full-screen TUIs (vim/htop render line-based) and
  no job-control `Ctrl-Z`; errandsh covers the common REPL case.
- Tailscale-ssh (port 22 path) is exec-only in this environment; use tailcat
  for interactive sessions.
- `chroot` must be permitted (it is on our host; plain `unshare`/`bwrap` were
  not needed).

## Versions

Tested with tailscale 1.102.4, tailcat 0.6.0, bash 5.3, python 3.14, linux
6.18 (gentoo), glibc/musl-free (static Go binaries + tiny preload shims).
