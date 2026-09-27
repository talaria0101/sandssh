# Decision: adopt before install, and prove it with a probe

Date: 2026-09-27. Status: settled.

## The rule

`sh_toolchain_ensure` asks the module's `tc_<name>_probe` first. A toolchain that
already answers is **adopted**: nothing is downloaded and no tree is mirrored.
Only a probe that fails leads to `tc_<name>_install`.

The last word is also a probe. After `tc_<name>_env` writes the fragment and the
environment is loaded, the probe runs again, and a failure is reported:

```
toolchain go installed without an error and still does not run from the exec view
```

## Why

- A sandbox that already carries a toolchain is the common case, and downloading
  a second copy of rust only to find the first one fills a small exec root.
- An install command's exit code is not evidence that the tool runs. On the
  split root the failure mode is precise: the binary landed on the home, which
  refuses `execve`. A report claiming the tool is present because a copy command
  exited 0 is the class of claim this tree exists to refuse.

## A defect this found

`sh_promote_toolchain` returned early when the home was itself exec-capable,
before linking the module's executables into `$SANDHOME_EXEC/bin`. A toolchain
that installed correctly into an exec-capable home was therefore absent from
every shell, and the post-promote probe caught it. The regression is pinned in
`tests/bootstrap.sh` ("the promoted jq is on the exec root") and
`tests/space.sh`.

## A defect the first version of this had

The second bootstrap of an already-set-up sandbox re-downloaded `jq`, because the
probe ran against a `PATH` that did not yet carry the exec view. `bootstrap.sh`
now calls `sh_env_load` after planning the roots and before deciding anything.
`tests/bootstrap.sh` asserts the second run reports `adopted=jq` and does not
report `installed=jq`.

## The same defect, one layer down

`bootstrap.sh` was not the only path. A toolchain reached **only through its own
PATH fragment** — `go`, `rust`, `uv` — is invisible on `PATH` in a fresh shell
until that fragment is sourced, and `sh_toolchain_install_one` probed before
loading anything. Every second `sandhome install go` in a new shell downloaded
the whole tarball while a working copy sat in the home. It now calls
`sh_env_load` before the probe, and `tests/toolchain.sh` pins it with a module
whose binary is reachable only through its fragment: the first ensure installs,
the second in a fresh shell adopts and does not install.

## What the post-promote probe has caught

Two installers reported success while producing something that did not work, and
the probe caught both:

- `npm` was copied to the wrong path, so `node` answered and `npm` died with a
  module-not-found error;
- `go`'s `GOCACHE` was on the noexec home, so `go version` answered and `go run`
  failed with `fork/exec ... permission denied` after compiling.

Both are why the probe runs the tool rather than asking whether a file exists.
The version chains had a third shape of their own: a `read` that returns non-zero
at EOF without a newline made `sh_first_line`/`sh_first_word` answer nothing while
the command ran fine, which silently broke Go's version lookup.
