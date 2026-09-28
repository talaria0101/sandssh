# The reverse relay protocol, measured 2026-09-28

**This is a measurement record, not a design.** It exists because the previous
record of the same protocol in this tree was wrong in a way that would have cost
an implementer an afternoon, and because a measurement that lives only in
another repository's commit message is a measurement nobody finds.

Everything below was produced by driving a live pair against
`tcp.ssh.relay.ajam.dev` from inside the sandbox described in issue 11: a
sealed cage with no `bind(2)` even at uid 0, no `/dev/ptmx`, no `/etc/passwd`,
no resolver, and an egress that reaches only an HTTP CONNECT proxy which
answers `200 Connection Established` on 443 and `403 not on the egress
allowlist` on every other port.

The instrument is a node script using the `ws` client, run through the proxy.
Every row below is one run; the rows that say "3/3" were run three times
consecutively with identical results.

---

## The asymmetry, and why it is the whole protocol

Both peers dial out. The node's socket is long-lived and carries every session
at once. A session is **32 ASCII hex characters**, and the two legs are **not
symmetric**:

| direction | the peer sends | the relay does | the far side receives |
| --- | --- | --- | --- |
| operator -> node | **bare payload, no id** | prepends the session id | `id + payload` |
| node -> operator | **`id + payload`** | strips the id | **bare payload** |

Measured, one live session:

```
operator sends "OPBARE"  (6 bytes)  ->  node receives 38 bytes:
                                        "71cca90e15bd41d580523e4a8fe398f1OPBARE"
operator sends <id>+"OPID" (38 B)   ->  node receives 68 bytes:
                                        "<real id>" + "<id>" + "OPID"
node sends "NDBARE"      (6 bytes)  ->  NODE CLOSED 1009 "bad multiplex frame"
                                        operator then closed 1011
node sends <id>+"NDID"   (38 bytes)  ->  operator receives 4 bytes: "NDID"
```

⛔ **A NODE FRAME WITH NO ID IS NOT DROPPED IN SILENCE.** This is the
correction, and it is the reason this file exists. An earlier revision of this
tree's research, and five places in `dropssh`, said a bare node frame is
"silently discarded: no error, no close, and the session goes quiet". Re-measured
live, 3/3: the **node** socket is closed with **1009 `bad multiplex frame`** and
the operator is then closed with **1011 `node disconnected`**.

We cannot say the relay *changed*. The old measurement is from 2026-09-27 and
there is no instrumented run from that day. The honest statement is that the
document and the live relay disagreed, and the live relay is what an implementer
meets. `dropssh/docs/reverse-relay.md` now carries 1009 in its error table and
`dropssh/tests/mux-probe.py` asserts the close, so the claim is in a test.

## The close codes, which are three different bugs

| close | side | trigger | what an implementer does about it |
| --- | --- | --- | --- |
| `1003` `binary frames required` | operator, or node | a **text** frame on a data leg | the frame writer chose the wrong opcode. In C the opcode is a parameter, so this is a one-line fix **and it must be logged distinctly from 1009** |
| `1008` `wait for ready` | operator | session data sent **before** the node answered `open` with `ready` | hold stdin until `ready`. Both ends are torn down: the operator with 1008, the node with `1003` `unknown session id` |
| `1009` `bad multiplex frame` | node | a data frame with **no 32-hex id** | prefix the id, in the same frame |
| `1011` `node disconnected` | operator | the node's socket went away | a consequence, not a diagnosis. Reporting only this cannot tell a framing bug from the relay being down |

⛔ **A NODE SENDING A TEXT `ready` ON THE DATA LEG IS SILENTLY IGNORED** by the
ajam relay, which is different again from the 1003 an *operator* gets for the
same mistake. Measured, 2/2. Our own relay closes 1003 for both, because
silently ignoring a peer's control frame is the same class of failure as B11.

## The rest of the protocol, as measured

* `POST /v1/pair` with `{}` is self-service and answers `name`, `node_token`,
  `connect_token`, `stop_token`, `expires`. The two tokens are **different** and
  scoped to their own role.
* `hello` is `{"type":"hello","version":1,"maxFrameBytes":65536,"maxSessions":64}`.
  A node that reads them and enforces them cannot be closed by the relay for
  exceeding a limit it agreed to.
* An operator that upgrades **before** the node is connected is answered
  **`503` on the upgrade**, not accepted and then dropped.
* `/v1/status/{name}` takes the **connect_token only**; `node_token` and
  `stop_token` both get `403 "reverse: forbidden"`. A status poll that 403s
  reads as "the node is unreachable" rather than "you presented the wrong
  credential".
* A `node_token` on another pair's name is 403; another pair's `node_token` on
  this name is 403; a second node on a taken name is 409.
* A bogus 32-character id from the operator is **rewritten, not rejected**: the
  node receives `<real id>` + the original payload, 68 bytes. Not exploitable
  across pairs, but it means **the id in an operator frame is not addressing and
  must not be treated as it**.

## What this changes about the seven tools in issue 2

Nothing architectural. The references in issues 4 to 10 were read for their
mechanisms, and the mechanisms land inside the multiplexer rather than beside
it:

* **chisel** (issue 4): `ready`/`reject{id,reason}` with a bounded wait, and
  ACL per channel re-read live. Both are in the implemented `open` handling.
* **ligolo-ng** (issue 5): the agent-dials-out shape, a standard multiplexer
  with per-stream windows, and a **total** reconnection budget that is visible.
  The yamux-over-our-framing question is still open and is named as such.
* **wiretap** (issue 6): the operator-side SOCKS capability is genuinely missing
  and belongs in dropssh. Out of scope for this sweep.
* **curlshell** (issue 7): the `curl | sh` bootstrap is **sandhome's** job, not
  a second transport.
* **sshx** (issue 8): the latency estimate belongs in `dropssh doctor`, which
  now exists.
* **websocat / Cloudflare** (issue 9): refused. The cage reaches a 443 relay
  today and would not be able to deploy a worker.
* **awesome-tunneling** (issue 10): confirms the maintainer's own "I haven't
  found a tool that does all of this", and its tracker is the real artefact:
  every hosted tunnel in that category has been dead, moved or relicensed.

**The answer to issue 2's "or maybe a single tool that includes what actually
works" is: the single tool already exists.** It is `dropssh`, it is C, it is
one static binary, and the gap was inside it. Implementing the multiplexer once,
there, is what this work did. **No new repository.**

## Reproducing

```sh
# from inside the sealed cage, through its CONNECT proxy
NODE_USE_ENV_PROXY=1 node tests/relay-probe.mjs
```

The probe opens a pair, answers `open` with `ready`, and prints the four-way
table, the three closes and the auth matrix above. The same assertions run
against a local relay in `dropssh/tests/mux-probe.py`, which is part of that
project's gate and needs no network and no credential.
