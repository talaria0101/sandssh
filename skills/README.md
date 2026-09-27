# Skills

This directory follows the [Agent Skills standard](https://agentskills.io/specification):
each subdirectory holds a `SKILL.md` with `name` and `description` frontmatter,
and everything else beside it is freeform. Pi discovers them from a package's
`skills/` directory, and from `~/.agents/skills/` or `~/.pi/agent/skills/` once
copied or linked there.

| skill | use it when |
| --- | --- |
| [`sandhome`](sandhome/SKILL.md) | a sandbox needs tooling, `HOME` is noexec, or a tool installed but will not run |
| [`errandsh`](errandsh/SKILL.md) | a remote shell has no echo, line editing or signals because there is no pty |
| [`sealed-sandbox`](sealed-sandbox/SKILL.md) | a cage denies bind, chroot, `/etc/passwd` or a terminal |

To make them available to an agent without copying:

```sh
ln -s "$PWD/skills" "$HOME/.agents/skills/sandhome"
```

The instructions inside each skill point at the guides and decisions in `docs/`
for the reasoning; the skill is the entry point, not the whole story.
