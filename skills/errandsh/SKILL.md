---
name: errandsh
description: Drive an interactive shell over a pty-less SSH session with errandsh — echo, line editing, history, tab completion and Ctrl-R where there is no /dev/ptmx. Use when a remote shell has no echo or line editing, when ssh -t degrades to a dumb pipe, or when testing a pty-less session.
---

# errandsh

`errandsh` is a line discipline for a session that has no pty. A sealed cage has
no `/dev/ptmx` and no devpts, so a remote shell arrives with no echo, no line
editing and no signals. `errandsh` provides those in POSIX `sh`.

## Run it

```sh
sandhome shell                 # interactive
sandhome shell -c 'make test'  # exec channel, no line discipline
sh shell/errandsh              # from the checkout
```

As a remote login shell, set it on the server side and connect with plain `ssh`:

```sh
ssh -o ProxyCommand='...' user@host
# with the server's login shell set to errandsh
```

Environment: `ERRANDSH_NAME` (prompt name), `ERRANDSH_HISTORY` (history file),
`ERRANDSH_SHELL` (child shell, default `/bin/sh`), `ERRANDSH_MAXHIST`,
`NO_COLOR`.

## What it does and does not do

It gives echo, a prompt carrying the last exit code, history with Up/Down,
Left/Right/Home/End/Delete, `Ctrl-A E B F K U W`, `Ctrl-R` reverse search, tab
completion, and bracketed paste.

It cannot run a full-screen TUI: nothing in userspace can create `/dev/ptmx`.
While a command runs the session is not reading keys, so `Ctrl-C` is delivered by
the operator's own client and type-ahead is read after the command finishes.

## Test it

```sh
bash tests/errandsh-posix.sh
```

The test drives it over pipes — not a pty — under every shell the host has, and
asserts the recalled text and the cursor-walk escape, because a cursor movement
on a short line looks like no movement at all.

## The related shims

When a program other than an interactive shell needs to believe a pipe is a
terminal, `fakepty.so` is the `LD_PRELOAD` interposer. Neither shim can reach a
static binary. See `skills/sealed-sandbox/SKILL.md`.
