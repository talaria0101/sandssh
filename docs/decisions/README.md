# Decisions

Each page records a shape that is settled, and the measurement or reason behind
it. A later session should read the relevant one before changing an interface it
describes.

| page | what it settles |
| --- | --- |
| [`exec-split.md`](exec-split.md) | data and executables may live on different roots; shared objects are symlinked, binaries copied |
| [`adopt-before-install.md`](adopt-before-install.md) | a working toolchain is adopted; every install ends in a probe |
| [`toolchain-contract.md`](toolchain-contract.md) | what a `tools/<name>.sh` module declares and the rules behind it |
| [`posix-sh-only.md`](posix-sh-only.md) | POSIX `sh`, no `local`, and a deliberately tiny dependency set |
| [`fetching-and-digests.md`](fetching-and-digests.md) | one download path, digests read from the release, and the schema traps in the version chains |
