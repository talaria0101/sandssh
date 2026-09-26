// ssh-relay Worker: expose a fixed TCP target (e.g. railway.new:22) as a
// WebSocket on your own Cloudflare edge, and splice raw bytes between the
// socket and that WebSocket. The Worker dials the target with connect(),
// which is a plain outbound TCP socket; the client is a normal `ssh` that
// speaks SSH over this WebSocket via a ProxyCommand. No VPC, no Tunnel, no
// agent, no server to run. Cloudflare fronts it on 443.
//
// Protocol: 101 WebSocket upgrade at /, then an opaque bidirectional byte
// stream. The first bytes the client sends are the SSH version string, and
// the first bytes we send back are the target's SSH banner. There is no
// VLESS framing and no auth: put Cloudflare Access or an allowlist in front
// if you need to keep it private.
//
// The target is pinned in CFG so a caller cannot use this Worker as an open
// relay to arbitrary destinations. Edit CFG and redeploy to change it.

import { connect } from "cloudflare:sockets";

const CFG = {
  host: "railway.new", // the TCP-only target, e.g. an SSH gateway
  port: 22,
  banner: "SSH-2.0-Go", // expected first bytes from target; we verify
  verifyBanner: true,
  connectTimeoutMs: 10_000,
};

// Health check: GET /  ->  a tiny JSON status. Any non-WS request returns
// this, so `curl https://<worker>.workers.dev` confirms the Worker is up.
const health = () =>
  new Response(
    JSON.stringify({ ok: true, target: `${CFG.host}:${CFG.port}` }),
    { headers: { "content-type": "application/json" } },
  );

async function handleWebSocket(req) {
  const [client, server] = Object.values(new WebSocketPair());
  // allowHalfOpen so we can keep reading the target after the client stops
  // sending, and close cleanly when either side ends.
  server.accept({ allowHalfOpen: true });
  server.binaryType = "arraybuffer";

  let socket = null;
  let reader = null;
  let writer = null;
  let closed = false;

  const cleanup = () => {
    if (closed) return;
    closed = true;
    try { reader?.releaseLock(); } catch {}
    try { writer?.releaseLock(); } catch {}
    try { socket?.close(); } catch {}
    try { server.close(); } catch {}
  };

  // Open the TCP connection to the target, verifying it is really SSH.
  const openTarget = async () => {
    const sock = connect({ hostname: CFG.host, port: CFG.port });
    await Promise.race([
      sock.opened,
      new Promise((_, rej) =>
        setTimeout(() => rej(new Error("connect timeout")), CFG.connectTimeoutMs),
      ),
    ]);
    return sock;
  };

  // target -> websocket
  const pumpDown = async () => {
    reader = socket.readable.getReader();
    // Read the banner first so a wrong-target (or non-SSH) endpoint fails
    // fast and visibly instead of handing the client garbage.
    let banner = new Uint8Array(0);
    const dec = new TextDecoder();
    while (!banner.includes(0x0a) && banner.length < 256) {
      const { done, value } = await reader.read();
      if (done) throw new Error("target closed before banner");
      const chunk = new Uint8Array(value);
      const next = new Uint8Array(banner.length + chunk.length);
      next.set(banner); next.set(chunk, banner.length);
      banner = next;
    }
    const ident = dec.decode(banner).split("\n")[0].split(" ")[0];
    if (CFG.verifyBanner && ident !== CFG.banner) {
      throw new Error(`wrong target banner ${ident}`);
    }
    // Forward the banner, then keep streaming.
    if (banner.length) server.send(banner);
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value?.byteLength) server.send(new Uint8Array(value));
    }
  };

  // websocket -> target is handled in the message listener below, which also
  // opens the socket lazily on the first client byte. There is no separate
  // up pump. Setup is serialized so concurrent first-messages cannot
  // double-open the socket or interleave writer.write() calls, since a
  // WritableStream writer is not reentrant.
  let openPromise = null;
  const ensureSocket = async () => {
    if (writer) return;
    if (!openPromise) {
      openPromise = (async () => {
        socket = await openTarget();
        pumpDown().catch(cleanup);
        writer = socket.writable.getWriter();
      })();
    }
    await openPromise;
  };

  server.addEventListener("message", async (e) => {
    if (closed) return;
    try {
      const d = e.data instanceof ArrayBuffer ? new Uint8Array(e.data)
        : ArrayBuffer.isView(e.data) ? new Uint8Array(e.data.buffer, e.data.byteOffset, e.data.byteLength)
        : new Uint8Array(e.data);
      if (!d.byteLength) return;
      await ensureSocket();
      await writer.write(d);
    } catch { cleanup(); }
  });

  server.addEventListener("close", cleanup);
  server.addEventListener("error", cleanup);

  return new Response(null, {
    status: 101,
    webSocket: client,
    headers: { "Sec-WebSocket-Extensions": "" },
  });
}

export default {
  async fetch(req) {
    const upgrade = req.headers.get("Upgrade")?.toLowerCase();
    if (upgrade === "websocket") return handleWebSocket(req);
    if (req.method === "GET") return health();
    return new Response("ssh-relay: use a WebSocket (ssh ProxyCommand) or GET for health", {
      status: 426,
    });
  },
};
