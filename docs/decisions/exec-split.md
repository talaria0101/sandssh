# Decision: data and executables live on different roots

Date: 2026-09-27. Status: settled.

## The measurement

On the sandbox this was built in, `findmnt` shows `/workspace` and `/state`
mounted `rw` with no `noexec` in the option string. Writing works. A script
created there, marked `0700`, and run fails:

```
$ cp /bin/echo /workspace/echo.bin && /workspace/echo.bin
/bin/bash: /workspace/echo.bin: Permission denied
```

The refusal is a sandbox policy, not a mount flag, and it is invisible in
`/proc/mounts`. Two further probes bound what is refused:

```
$ python3 -c "import ctypes; ctypes.CDLL('/workspace/.../libstd-....so')"
CTYPES-DLOPEN-OK
```

`mmap(PROT_EXEC)` from the same mount is **allowed** while `execve` is not. That
asymmetry is the whole design: a shared object, an `.rlib`, a `GOROOT` or a
stdlib can stay on the big read-only-in-effect root, and only the executables
must move.

## The decision

Two roots, detected by running a real file rather than by reading mount options:

- `SANDHOME_HOME` — persistent data. May be noexec.
- `SANDHOME_EXEC` — must run a binary. Chosen by `sh_exec_probe`, which writes a
  `#!/bin/sh` file, chmods it, and runs it.

A toolchain installs into the home. When the home runs binaries the two roots
collapse and nothing is copied. When it does not, `sh_promote_tree` mirrors the
tree onto the exec root: **executable regular files are copied**, everything
else is symlinked back. Shared objects are explicitly excluded from the copy set
by `sh_is_exec_file`, because copying a 144MB `librustc_driver` or a 191MB
`libLLVM.so` onto a 400MB root is not possible.

The build target goes on the exec root too, because cargo and go must `execve`
build scripts, proc-macros and test binaries.

## What was measured end to end

- `jq` (a single static binary) installed into a noexec home, promoted, and run
  from a shell that read only `env.sh`: `jq JSON: 1`.
- Go installed into a noexec home, its `GOROOT/pkg/tool` promoted, and
  `go build` of a program run from the exec view: `hello from go`, exit 0.

## What this costs, stated plainly

- The exec root can be small, so a toolchain with a very large executable set
  can fill it. `sandhome space` reports free megabytes and `sh_space_need`
  refuses before a download. `go`'s build cache also lives there, because `go
  run` execs what it builds.

## The shape that was originally mis-copied

A first version dereferenced a symlinked executable and copied the target under
**the link's basename**. That is wrong whenever the target refers to itself
relatively. Node's `bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js` does
`require('../lib/cli.js')`; copied to `bin/npm`, it looked for `bin/../lib/cli.js`
and npm died. Leaving the link pointing at the home does not work either: a
shebang script whose inode is on a noexec mount is refused at `execve` with `bad
interpreter: Permission denied`. The rule is now: mirror the symlink into the
view, pointing at the target's own mirrored path, so the script itself is a copy
on the exec root and every relative path beside it resolves. Measured against the
real `npm` (v11.19.1) from the node v26.10.0 tarball, which now runs.
