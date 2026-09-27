# Decision: POSIX sh, and a deliberately tiny set of dependencies

Date: 2026-09-27. Status: settled.

## The rule

Every script here is `sh`, checked by `dash -n` and `bash --posix -n`
(`tests/syntax.sh`). No `local`, no arrays, no `[[`, no `$'...'`, and no
`a && b || c` — the last is permitted by a new shellcheck and reported as SC2015
by an old one, so it is not used at all.

The library uses the shell for what a userland might not carry. There is no
`awk`, `sed`, `grep`, `tr`, `find`, `install` or `dirname` in `lib/`:

- `sh_split_on` is `tr`'s job, in the shell.
- `sh_first_line` and `sh_first_word` are `head -1`, in the shell.
- `sh_free_mb` reads `df -Pk` with the shell rather than `awk`.
- `sh_script_dir` avoids `dirname`.
- `sh_append_once` is the one appender, so two call sites cannot drift.

## Why

A bootstrap whose job is to install the missing tools cannot require them to
already be there. Measured across minimal images, `Photon` carries neither `awk`
nor `tr`, openSUSE carries neither `awk` nor `find`, and Void and Rocky 8 carry
no `find`. The exceptions this file allows itself are `uname` and `id`.

The shell-only helpers are also the ones this repository can test without a
machine, which is why `tests/unit.sh` can assert `sh_split_on` and
`sh_json_escape` directly.

## One consequence worth naming

`local` does not exist, so a recursive shell function's variables are globals.
`sh_promote_tree` was recursive and its recursive call overwrote the parent's
iterator; the fix is a work queue (`docs/decisions/exec-split.md` records the
measurement). New code should avoid recursion for the same reason.
