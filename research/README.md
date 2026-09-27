# research

Measurements, kept because they are cited and because a number with no
conditions next to it is folklore.

`RELAY-BENCHMARKS.md` is the measured relay table: which public CONNECT
proxies carried a byte to which target, at what latency, over how many
runs, and the failure taxonomy over 15,532 candidates. podbox's
`crates/podbox-ssh/src/catalog.rs` cites it for every entry it ships, and
`docs/decisions/podssh-handoff.md` points here for the numbers.

The reading is from 2026-09-26 and 2026-09-27 and it is STALE by
construction: a shared public relay is perishable, and one of that day's
best was dead within three hours. `podssh probe` and
`experiments/401-podssh-relays.sh` in podbox re-measure rather than trust
it, which is the only reason this file is still useful.
