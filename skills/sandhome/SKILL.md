---
name: sandhome
description: Set up a portable agent sandbox with sandhome — detect where binaries may run, install toolchains (jq, ripgrep, fd, python, node, rust, go), write the environment, and diagnose a tool that installed but will not run. Use when a fresh sandbox needs tooling, when HOME is on a noexec mount, or when a build fails because a tool is missing or cannot execute.
---

# sandhome

`sandhome` turns a bare userland into a working one. The single fact to hold onto
is that **a writable mount can still refuse `execve`**, so data and executables
may need different roots.

## Set up

From a checkout:

```sh
sh bootstrap.sh --toolset developer
```

From a pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandssh/main/bootstrap.sh \
  | sh -s -- --toolset developer
```

Toolsets: `minimal` (jq), `cli` (jq, ripgrep, fd), `developer` (adds python,
node), `languages` (adds rust, go), `agent` (everything). Add one off with
`--with rust`; drop one with `--without node`.

Use `--dry-run` first when unsure. Exit `0` done, `1` something could not be
installed, `2` could not run.

## Use the environment

```sh
. "$HOME/.local/share/sandhome/env.sh"
eval "$(sandhome env)"        # equivalent, without sourcing a file
sandhome doctor               # pass/fail view of the invariants
sandhome space --probe        # every root, and whether it runs a binary
```

## Install or adopt a toolchain later

```sh
sandhome toolchains           # what this tree can set up
sandhome install rust go      # adopts a working copy, installs otherwise
```

If a toolchain is already present it is adopted and nothing is downloaded.

## Diagnose a tool that will not run

1. `sandhome space --probe` — is the exec root the one you think?
2. `sandhome install <name>` — rebuilds the exec view and probes at the end.
3. `sandhome doctor` — checks that the env file, the exec bin and the shims
   exist.

The failure this catches: a toolchain installed into a noexec home, so the
binary is there and `Permission denied`. Re-running `install` promotes it.

## Add a toolchain

Create `tools/<name>.sh` following the contract in `docs/guide.md` section 4. The
module installs into `$(sh_toolchain_root <name>)`, declares its executables in
`TC_<name>_BINS`, and must not test a binary by its home path — it may not run
there.

The decisions behind the shape are in `docs/decisions/`.
