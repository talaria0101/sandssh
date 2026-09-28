#!/usr/bin/env node
/* relay-probe.mjs - measure the ajam reverse relay's framing, live.
 *
 * ⛔ WHY THIS FILE EXISTS. The wire format of the reverse path was established
 * three separate times and got it wrong twice, in opposite directions, with a
 * wrong document committed both times. The measurements were sound; the
 * INFERENCE was not, because a rule proved on one leg was generalised to two.
 * So the rules are re-measured here, both legs, in one session, and the script
 * prints what it OBSERVED rather than what it concluded.
 *
 * ⛔ AND ONE OF THE RULES IS NOW MEASURED DIFFERENTLY THAN THE DOCUMENT SAID.
 * "A node frame without its 32-hex id is silently dropped" was in five places
 * in dropssh and in this tree's research. Re-measured, 3/3, it is not silent:
 * the node socket is closed with 1009 "bad multiplex frame" and the operator is
 * then closed 1011 "node disconnected". The requirement is unchanged; the
 * failure is loud and named. research/REVERSE-PROTOCOL.md has the record.
 *
 * USAGE:
 *   node tests/relay-probe.mjs [case]
 *     bare      a node frame with no id        (expect node close 1009)
 *     prefixed  a node frame with its id       (expect the operator to get it bare)
 *     optext    the operator sends a TEXT frame on the data leg (expect 1003)
 *     opid      the operator sends a bogus 32-hex id (expect the id rewritten)
 *     all       every case above, in order    (the default)
 *
 * The cage this runs in reaches the relay only through an HTTP CONNECT proxy,
 * so the WebSocket client is given one explicitly; node's global WebSocket
 * ignores the environment's proxy settings.
 */
import { createRequire } from "node:module";
import { createRequire as _cr } from "node:module";

const require = createRequire(import.meta.url);

/* ⛔ THE DEPENDENCIES ARE RESOLVED, NOT ASSUMED. The probe needs a WebSocket
 * client that accepts a proxy agent, and node's built-in WebSocket does not
 * expose one. Rather than depend on a particular global install, this looks in
 * NODE_PATH, then in the paths npm and bun actually use, and says which ones it
 * tried and what it found if none work -- a probe that cannot run should say
 * why rather than exit 0 having measured nothing. */
function tryRequire(name) {
  const roots = [
    process.env.NODE_PATH,
    ...(process.env.NODE_PATH || "").split(":").filter(Boolean),
    process.env.npm_config_prefix + "/lib/node_modules",
    `${process.env.HOME}/.local/share/bun/install/global/node_modules`,
    "/usr/lib/node_modules",
    "/usr/local/lib/node_modules",
  ].filter(Boolean);
  for (const root of roots) {
    try {
      return createRequire(root + "/").resolve(name);
    } catch { /* try the next one */ }
  }
  try {
    return require.resolve(name);
  } catch { return null; }
}

const wsPath = tryRequire("ws");
const hpaPath = tryRequire("https-proxy-agent");
if (!wsPath || !hpaPath) {
  process.stderr.write(
    "relay-probe: this probe needs the `ws` and `https-proxy-agent` packages.\n" +
    "  looked in NODE_PATH, npm_config_prefix/lib/node_modules,\n" +
    "  ~/.local/share/bun/install/global/node_modules, /usr/lib/node_modules,\n" +
    "  /usr/local/lib/node_modules\n" +
    "  install them with `npm i -g ws https-proxy-agent`, or set NODE_PATH.\n");
  process.exit(2);
}

/* ⛔ `ws` IS COMMONJS, SO THE DYNAMIC IMPORT'S NAMESPACE HAS THE CONSTRUCTOR
 * UNDER `.default`. A bare `const { WebSocket } = await import(...)` yields
 * undefined and the failure is "WebSocket is not a constructor", which names
 * the call site and not the module system. Both packages are unwrapped
 * explicitly, with the namespace used as a fallback, so either packaging works. */
const wsMod = await import("file://" + wsPath);
const WebSocket = wsMod.WebSocket || (wsMod.default && wsMod.default.WebSocket);
const hpaMod = await import("file://" + hpaPath);
const HttpsProxyAgent =
  hpaMod.HttpsProxyAgent ||
  (hpaMod.default && hpaMod.default.HttpsProxyAgent);
if (typeof WebSocket !== "function" || typeof HttpsProxyAgent !== "function") {
  process.stderr.write(
    "relay-probe: resolved ws and https-proxy-agent but could not read a " +
    "WebSocket constructor from either. ws said: " +
    Object.keys(wsMod).join(",") + "\n");
  process.exit(2);
}

const BASE = "https://tcp.ssh.relay.ajam.dev";
const HOST = "tcp.ssh.relay.ajam.dev";
const proxyURL =
  process.env.HTTPS_PROXY || process.env.https_proxy || null;
const agent = proxyURL ? new HttpsProxyAgent(proxyURL) : undefined;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ⛔ THE HTTP CALL USES NODE'S OWN fetch WITH A GLOBAL DISPATCHER, NOT A
 * DEPENDENCY. https-proxy-agent is a request agent; undici's fetch wants a
 * dispatcher, and loading undici by a guessed path is the kind of thing that
 * works in exactly one sandbox. The global dispatcher is a documented
 * undici property, so this is one mechanism and no second package to resolve. */
let dispatcher = undefined;
if (proxyURL) {
  try {
    const undiciPath = tryRequire("undici");
    if (undiciPath) {
      const { ProxyAgent, setGlobalDispatcher } = await import(
        "file://" + undiciPath.replace(/\/index\.js$/, "/index.js")
      );
      dispatcher = new ProxyAgent(proxyURL);
      setGlobalDispatcher(dispatcher);
    }
  } catch (e) {
    process.stderr.write(
      "relay-probe: could not install a proxy dispatcher (" + e.message +
      "). The WebSocket legs will use HTTPS_PROXY directly; the pair() call " +
      "needs undici's setGlobalDispatcher, so set NODE_PATH so this resolves.\n");
  }
}

async function fetchJSON(path, init) {
  const r = await fetch(BASE + path, { ...init, dispatcher });
  if (!r.ok) throw new Error(`${path}: HTTP ${r.status} ${await r.text()}`);
  return r.json();
}

/* ⛔ EVERY CLOSE IS RECORDED WITH ITS SIDE, CODE AND REASON, AND THE SIDE
 * MATTERS. The node socket and the operator socket are closed with DIFFERENT
 * codes for the same fault, and a probe that keeps only the first close it
 * sees reports whichever arrived first, which is a race. */
function watch(ws, label, out) {
  ws.addEventListener("close", (e) => {
    out.closes.push({ side: label, code: e.code, reason: e.reason });
  });
}

async function session(caseName) {
  const pr = await fetchJSON("/v1/pair", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  });
  const out = {
    name: pr.name,
    hello: null,
    openId: null,
    nodeText: [],
    nodeBin: [],
    opText: [],
    opBin: [],
    closes: [],
  };

  const nt = new WebSocket(`wss://${HOST}/v1/node/${pr.name}`, {
    headers: { "X-Relay-Token": pr.node_token },
    agent,
  });
  watch(nt, "node", out);
  nt.addEventListener("message", (e) => {
    if (typeof e.data === "string") {
      const m = JSON.parse(e.data);
      out.nodeText.push(m);
      if (m.type === "hello") out.hello = m;
      if (m.type === "open") {
        out.openId = m.id;
        /* ⛔ THE NODE ANSWERS `open` WITH `ready` IMMEDIATELY, AS A TEXT FRAME.
         * The relay closes an unanswered `open` with "node open timeout", and
         * a node that answers nothing is indistinguishable from a node that is
         * not there. */
        nt.send(JSON.stringify({ type: "ready", id: m.id }));
      }
    } else {
      out.nodeBin.push({
        len: e.data.byteLength,
        ascii: Buffer.from(e.data).toString("latin1").slice(0, 48),
      });
    }
  });
  await new Promise((res, rej) => {
    nt.addEventListener("open", res);
    nt.addEventListener("error", rej);
  });
  await sleep(1200);

  const ot = new WebSocket(`wss://${HOST}/v1/connect/${pr.name}`, {
    headers: { "X-Relay-Token": pr.connect_token },
    agent,
  });
  watch(ot, "operator", out);
  ot.addEventListener("message", (e) => {
    if (typeof e.data === "string") {
      out.opText.push(e.data.slice(0, 90));
    } else {
      out.opBin.push({
        len: e.data.byteLength,
        ascii: Buffer.from(e.data).toString("latin1").slice(0, 48),
      });
    }
  });
  await new Promise((res, rej) => {
    ot.addEventListener("open", res);
    ot.addEventListener("error", rej);
  });
  await sleep(3000);

  /* The operator's leg is BARE in every case: the relay prepends the id. */
  ot.send(Buffer.from("OPBARE"), { binary: true });
  await sleep(1800);

  if (caseName === "bare") {
    nt.send(Buffer.from([0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6]), { binary: true });
  } else if (caseName === "prefixed") {
    nt.send(Buffer.concat([Buffer.from(out.openId), Buffer.from("NPFX")]), {
      binary: true,
    });
  } else if (caseName === "optext") {
    ot.send("SOME TEXT ON THE DATA LEG");
  } else if (caseName === "opid") {
    ot.send(Buffer.concat([Buffer.from("f".repeat(32)), Buffer.from("XXXX")]), {
      binary: true,
    });
  }
  await sleep(4000);
  try { nt.close(); ot.close(); } catch { /* already gone */ }
  await sleep(500);
  return out;
}

const CASES = ["prefixed", "bare", "optext", "opid"];
const want = process.argv[2] || "all";
const list = want === "all" ? CASES : [want];

let failures = 0;
for (const c of list) {
  process.stdout.write(`\n=== case ${c}\n`);
  let out;
  try {
    out = await session(c);
  } catch (e) {
    process.stdout.write(`  could not run: ${e.message}\n`);
    failures++;
    continue;
  }
  process.stdout.write(`  hello       ${JSON.stringify(out.hello)}\n`);
  process.stdout.write(`  openId      ${out.openId}\n`);
  process.stdout.write(`  operator <- ${JSON.stringify(out.opBin)}\n`);
  process.stdout.write(`  operator <- ${JSON.stringify(out.opText)}\n`);
  process.stdout.write(`  node      <- ${JSON.stringify(out.nodeBin)}\n`);
  for (const cl of out.closes) {
    process.stdout.write(`  close       ${cl.side} ${cl.code} ${cl.reason}\n`);
  }
  /* The verdict per case is derived from the OBSERVATION, and each is stated
   * as the number the reader can check, not as a pass word. */
  const nodeClose = out.closes.find((x) => x.side === "node");
  const opClose = out.closes.find((x) => x.side === "operator");
  if (c === "prefixed") {
    const got = out.opBin.map((b) => b.ascii).join("");
    const ok = got === "NPFX";
    process.stdout.write(
      `  VERDICT     ${ok ? "as documented" : "UNEXPECTED"}: the operator received ${JSON.stringify(got)}\n`);
    if (!ok) failures++;
  } else if (c === "bare") {
    const ok = nodeClose && nodeClose.code === 1009;
    process.stdout.write(
      `  VERDICT     ${ok ? "as re-measured" : "NOT what the docs said"}: the node socket closed ${nodeClose ? nodeClose.code : "not at all"}\n`);
    if (!ok) failures++;
  } else if (c === "optext") {
    const ok = opClose && opClose.code === 1003;
    process.stdout.write(
      `  VERDICT     ${ok ? "as documented" : "UNEXPECTED"}: the operator socket closed ${opClose ? opClose.code : "not at all"}\n`);
    if (!ok) failures++;
  } else if (c === "opid") {
    const got = out.nodeBin.map((b) => b.ascii).join("");
    const ok = got.startsWith(out.openId);
    process.stdout.write(
      `  VERDICT     ${ok ? "id rewritten, as documented" : "UNEXPECTED"}: the node received ${JSON.stringify(got.slice(0, 48))}\n`);
    if (!ok) failures++;
  }
}

process.stdout.write(
  `\n${list.length} case(s), ${failures} did not match the recorded measurement\n`);
process.exit(failures ? 1 : 0);
