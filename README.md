# sandhome

A portable home for agents that run inside an errand/bailey-style sandbox: one
bootstrap, one environment, and a set of skills, guides and tools that turn a
bare userland into a place where work can actually happen.

The one problem it exists for is measured, not assumed: **a mount can be writable
and still refuse `execve`.** A sandbox can point `HOME` at a large disk that
reads and writes fine and denies execution, while `/tmp` allows it and is small.
Every hand-built userland handles that differently, and the difference is found
weeks later inside a job that fails for a reason nobody wrote down. `sandhome`
splits the two: data on the big root, executables on the root that runs them.

## Quick start

```sh
# from a clone
sh bootstrap.sh --toolset developer

# or from a pipe
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandssh/main/bootstrap.sh \
  | sh -s -- --toolset developer
```

Then, in any new shell:

```sh
. "$HOME/.local/share/sandhome/env.sh"   # or let the installed profile do it
sandhome doctor
sandhome space --probe
```

## What it sets up

| piece | what it does |
| --- | --- |
| `bootstrap.sh` | detects the machine, plans the two roots, adopts or installs the toolchains, builds the shims a cage needs, writes the environment and reports what it read |
| `bin/sandhome` | `doctor`, `env`, `path`, `space`, `toolchains`, `install`, `shims`, `shell`, `exec`, `report`, `gc` |
| `lib/` | the POSIX-sh library: detection, the exec/space plan, fetch+digest, env, the toolchain contract, shims, report |
| `tools/` | one module per toolchain: `jq`, `ripgrep`, `fd`, `python`, `node`, `rust`, `go` |
| `shims/` | `fakepty` (an isatty/termios interposer) and `fakepwd` (a synthetic passwd database) |
| `shell/errandsh` | a POSIX-sh line discipline for pty-less SSH sessions |
| `skills/` | Agent Skills this home provides |
| `docs/` | the guide and the decisions behind each shape |

Everything is POSIX `sh`. The library depends on the shell and almost nothing
else: not `awk`, not `sed`, not `grep`, not `tr`, not `find`, not `install`. A
bootstrap whose job is to install the missing tools cannot require them first.

## Why two roots

`sandhome space --probe` is the report to read when a toolchain will not run. On
the sandbox this was built in:

```
candidate=/workspace   writable=yes exec=no  free_mb=191000
candidate=/dev/shm     writable=yes exec=yes free_mb=244
candidate=/tmp         writable=yes exec=yes free_mb=414
```

`/workspace` is where the data wants to live and cannot run a binary. Executables
are copied to the exec root; shared objects are **symlinked**, because
`mmap(PROT_EXEC)` is allowed where `execve` is not, and copying a 191MB
`libLLVM.so` onto a 400MB root would not fit. See
[`docs/decisions/exec-split.md`](docs/decisions/exec-split.md).

## The rest of this repository

`sandssh`'s ssh transport and the podbox interop live on here unchanged:
`bin/sandssh` (the Python client), `relay/sandssh-relay.py`, `patches/`, and the
`research/` measurements. `CLEANUP.md` records what was removed and what replaced
it. `sandhome` is the layer above them.

## Tests

```sh
sh tests/run.sh
```

Green means every clause passed; the runner prints `passed`, `skipped` and
`failed` separately, because "could not run" is a different claim from "passed".

## Licence

See [`LICENSE`](LICENSE).
