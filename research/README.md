# research

Measurements, kept because a number with its conditions attached is evidence and
a number without them is folklore.

## `RELAY-BENCHMARKS.md`

The measured relay table from 2026-09-26: which public CONNECT proxies carried
a byte to which target, at what latency, over how many runs, and the failure
taxonomy over 15,532 candidates. The file states the sandbox it was taken on,
the VM shape, the trial window and how exit codes were read.

**It is stale by construction.** A shared public relay is perishable, and one of
that day's best was dead within three hours. It is kept because the METHOD is
reusable and the numbers are a baseline, not because the relays are expected to
be up. Re-measure before relying on any row in it.

## Adding a measurement

State, at the top of the file and before any table:

1. **the machine** it was taken on, including the kernel, the uid, and what is
   missing (`no /etc/passwd`, `no bind`, `no pty`);
2. **the window**, with `date -u` before and after, not a recollection;
3. **how each number was read**, specifically whether an exit code was read
   from the process itself rather than through a pipe, because a pipe reports
   the pipe's status;
4. **the sample size** for every rate, and every number that is a single run
   marked as one.
