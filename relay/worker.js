/**
 * Spheres Relay v3 — Cloudflare Worker
 *
 * A blind store-and-forward relay. It moves opaque bytes between addresses it
 * cannot connect to any identity, and it can prove that only by construction:
 *
 *   * A mailbox address IS an Ed25519 public key derived from a secret that
 *     only the two participants share. Access is granted by signing a request
 *     with the matching private key, verified against the address itself. The
 *     relay stores no membership list and never learns who is talking to whom.
 *
 *   * v1 addressed rooms as base36(SHA256(salt + sortedPublicKeys) & 0xFFFFFFFF)
 *     and authenticated with *any* valid Ed25519 signature, never checking it
 *     against the room. Two consequences: the operator could reconstruct the
 *     entire social graph from public keys, and anyone could generate a
 *     throwaway keypair and read or delete any conversation's mail. Both are
 *     fixed here, and v1 routes are gone rather than deprecated.
 *
 *   * v3 adds the hub: one WebSocket per client instead of one per mailbox.
 *     A phone with thirty contacts used to hold ninety sockets (chat, feed and
 *     call channels each), each with its own reconnect loop and watchdog. The
 *     hub is a Durable Object named by a random id the client picks; the
 *     client subscribes to each mailbox over that socket by signing with the
 *     mailbox key, exactly as it would have signed a direct upgrade. The hub
 *     learns the same set of addresses the operator could already see one
 *     socket at a time; it does not learn whose they are.
 *
 * What the operator can still see: message sizes (bucketed by the client),
 * timing, that some address is active, and — new with the hub — which
 * addresses one client holds, which the per-socket design also exposed via
 * shared IP and timing. Removing those needs padding schedules and cover
 * traffic, which are not implemented.
 */

const VERSION = "6.0";

// ── Limits ───────────────────────────────────────────────────────────────────
// v1 had none of these: unlimited body size, unlimited keys per identity, and
// unlimited Durable Objects mintable by anyone.
const MAX_BODY_BYTES = 256 * 1024;
const MAX_MAILBOX_MESSAGES = 500;
const MAX_MAILBOX_BYTES = 8 * 1024 * 1024;
const MAX_PREKEY_BYTES = 4 * 1024;

// Blob storage for media. Chunked because a Durable Object storage value tops
// out at 128 KiB, and base64 inflates by 4/3. The client writes 48 KB of
// ciphertext per chunk; 64 MB of video is ~1,400 chunks.
const MAX_BLOB_CHUNK_BYTES = 96 * 1024;
const MAX_BLOB_CHUNKS = 1400;
const MAX_BLOB_BYTES = 64 * 1024 * 1024 * 4 / 3 + 1024 * 1024;

const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const SWEEP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const AUTH_WINDOW_MS = 5 * 60 * 1000;

// A hub subscription is renewed every time the client connects. One that has
// not been renewed for this long belongs to a client that is gone.
const SUBSCRIPTION_TTL_MS = 26 * 60 * 60 * 1000;
const MAX_SUBSCRIBERS = 16;

// Wake registrations (push). Renewed on every connect; dropped when stale, so
// a retired device stops being woken.
const WAKE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const WAKE_COALESCE_MS = 30 * 1000;

// Rate limiting, per Durable Object, for HTTP requests. Frames over an
// established socket were never rate limited and still are not; the mailbox
// byte and count quotas bound them instead.
const RATE_WINDOW_MS = 60 * 1000;
const MAX_REQUESTS_PER_WINDOW = 120;

// TURN credentials, when the operator has configured a coturn server with
// `use-auth-secret`. Short-lived so nothing in the binary can be scraped.
const TURN_TTL_S = 2 * 60 * 60;

/** 32-byte key encoded base64url — the shape of every address we accept. */
const ADDRESS_RE = /^[A-Za-z0-9_-]{43}=?$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * The namespace to mint objects from.
 *
 * `DO_JURISDICTION` pins where Durable Object storage lives — Cloudflare runs
 * the Worker wherever the user is, but the mailbox, blob and prekey objects
 * can be kept in one region. The default deployment uses "eu". Changing it
 * renames every object, so queued mail does not carry across.
 */
function namespace(env) {
  const j = env.DO_JURISDICTION;
  return j ? env.RELAY_ROOM.jurisdiction(j) : env.RELAY_ROOM;
}

function room(env, name) {
  const ns = namespace(env);
  return ns.get(ns.idFromName(name));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return json({
        service: "Spheres Relay",
        status: "blind",
        version: VERSION,
        jurisdiction: env.DO_JURISDICTION || null,
        turn: Boolean(env.TURN_SECRET && env.TURN_URLS),
        apns: Boolean(env.APNS_PRIVATE_KEY),
      });
    }

    // Sealed mailbox: /mbx/<address>[/sync|/ack|/subscribe|/publish|/unsubscribe|/wake]
    // Address is an Ed25519 public key derived from a shared secret. Every
    // operation, including the WebSocket upgrade, must be signed by it —
    // or, for publish and unsubscribe, carry the token a signed subscribe
    // handed out.
    const mbx = url.pathname.match(
      /^\/mbx\/([A-Za-z0-9_=-]+)(?:\/(sync|ack|subscribe|publish|unsubscribe|wake|post))?$/,
    );
    if (mbx) {
      if (!ADDRESS_RE.test(mbx[1])) {
        return new Response("Malformed mailbox address", { status: 400 });
      }
      return room(env, `mbx_${mbx[1]}`).fetch(request);
    }

    // Client hub: /hub/<client id>
    // The id is a random 256-bit capability the client mints per install. The
    // upgrade itself is unauthenticated; every subscription over it is signed
    // by the mailbox it names, so a guessed hub id yields nothing.
    const hub = url.pathname.match(/^\/hub\/([A-Za-z0-9_=-]+)$/);
    if (hub) {
      if (!ADDRESS_RE.test(hub[1])) {
        return new Response("Malformed hub id", { status: 400 });
      }
      return room(env, `hub_${hub[1]}`).fetch(request);
    }

    // Handshake inbox: /inbox/<identity public key>
    // Deliberately asymmetric — a stranger must be able to send a contact
    // request without a shared secret, so writes are unauthenticated. Reads
    // are signed with the identity key, so only the owner sees what arrived.
    const inbox = url.pathname.match(/^\/inbox\/([A-Za-z0-9_=-]+)(?:\/(sync|ack))?$/);
    if (inbox) {
      if (!ADDRESS_RE.test(inbox[1])) {
        return new Response("Malformed inbox address", { status: 400 });
      }
      return room(env, `inbox_${inbox[1]}`).fetch(request);
    }

    // Media blob: /blob/<address>/<chunk index>
    // The address is a 256-bit capability that only travels inside sealed
    // envelopes, and the bytes are encrypted before they arrive. Reads are
    // therefore unauthenticated — holding the address is the authorisation —
    // while writes are signed, so a blob cannot be overwritten by a passer-by.
    const blob = url.pathname.match(/^\/blob\/([A-Za-z0-9_=-]+)\/(\d{1,4})$/);
    if (blob) {
      if (!ADDRESS_RE.test(blob[1])) {
        return new Response("Malformed blob address", { status: 400 });
      }
      return room(env, `blob_${blob[1]}`).fetch(request);
    }

    // Prekey bundle: /prekey/<identity public key>
    // Public by necessity — a new contact needs your X25519 key before any
    // shared secret can exist. It carries nothing else. v1's /state endpoint
    // served display name and bio here, unauthenticated, to anyone holding a
    // public key.
    const prekey = url.pathname.match(/^\/prekey\/([A-Za-z0-9_=-]+)$/);
    if (prekey) {
      if (!ADDRESS_RE.test(prekey[1])) {
        return new Response("Malformed identity key", { status: 400 });
      }
      return room(env, `prekey_${prekey[1]}`).fetch(request);
    }

    // TURN credentials: /turn/<address>
    // Signed by any mailbox key the caller holds, which proves they are a
    // client rather than a passer-by looking for a free media relay. Stateless,
    // so it is answered here rather than in an object.
    const turn = url.pathname.match(/^\/turn\/([A-Za-z0-9_=-]+)$/);
    if (turn) {
      if (!ADDRESS_RE.test(turn[1])) {
        return new Response("Malformed address", { status: 400 });
      }
      return handleTurn(request, env, turn[1]);
    }

    return new Response("Not found.", { status: 404 });
  },
};

// ── TURN ─────────────────────────────────────────────────────────────────────

/**
 * Issue short-lived TURN credentials in the coturn `use-auth-secret` format:
 * username is `<expiry>:<label>`, credential is base64(HMAC-SHA1(secret,
 * username)). Nothing here is stored; coturn recomputes the HMAC.
 *
 * Refuses explicitly when the operator has not configured a server. The
 * client then falls back to whatever CallConfig says, and says so in the UI.
 */
async function handleTurn(request, env, address) {
  if (request.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!(await verifyRequestAuth(request, address, ""))) return unauthorized();

  if (!env.TURN_SECRET || !env.TURN_URLS) {
    return json(
      { error: "TURN is not configured on this relay", configured: false },
      501,
    );
  }

  const expiry = Math.floor(Date.now() / 1000) + TURN_TTL_S;
  // The label is a truncated hash of the address: coturn logs usernames, and
  // the mailbox address need not appear in a TURN log.
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(address),
  );
  const label = bytesToBase64Url(new Uint8Array(digest).slice(0, 8));
  const username = `${expiry}:${label}`;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.TURN_SECRET),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username));
  const credential = bytesToBase64(new Uint8Array(mac));

  const urls = env.TURN_URLS.split(",").map((u) => u.trim()).filter(Boolean);
  return json({
    configured: true,
    urls,
    username,
    credential,
    ttl: TURN_TTL_S,
  });
}

// ── Durable Object ───────────────────────────────────────────────────────────

export class RelayRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);
    const kind = segments[0]; // mbx | hub | inbox | blob | prekey
    const address = segments[1];
    const action = segments[2];

    // Hub-to-mailbox and mailbox-to-hub calls carry a token issued by a signed
    // subscription and are not rate limited: a busy conversation is not abuse.
    const internal =
      (kind === "hub" && action === "deliver") ||
      (kind === "mbx" && (action === "publish" || action === "post"));
    if (!internal && !(await this.underRateLimit())) {
      return new Response("Too many requests", { status: 429 });
    }

    await this.scheduleSweep();

    if (kind === "hub") return this.handleHub(request, url, address, action);
    if (kind === "blob") return this.handleBlob(request, address, action);
    if (kind === "prekey") return this.handlePrekey(request, address);
    if (kind === "inbox") return this.handleInbox(request, url, address, action);
    return this.handleMailbox(request, url, address, action);
  }

  // ── Sealed mailbox ─────────────────────────────────────────────────────────

  async handleMailbox(request, url, address, action) {
    // Every path here requires proof of the mailbox key. Crucially the key is
    // the address, so possession of *some* keypair proves nothing.
    if (action === "sync" && request.method === "GET") {
      if (!(await this.verifyAuth(request, address, ""))) return unauthorized();
      return json(await this.pending());
    }

    if (action === "ack" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();

      let ids;
      try {
        ids = JSON.parse(body).ids;
      } catch (_) {
        return new Response("Malformed body", { status: 400 });
      }
      if (!Array.isArray(ids)) return new Response("Malformed body", { status: 400 });

      await this.state.storage.transaction(async (txn) => {
        const pending = (await txn.get("mailbox")) || [];
        await txn.put("mailbox", pending.filter((m) => !ids.includes(m.id)));
      });
      return new Response("OK");
    }

    // A hub asking to receive this mailbox's traffic on behalf of a client.
    // The client signed `SUB<address><ts>` with the mailbox key; the hub only
    // forwards it. Verified here, against the address, so a hub cannot
    // subscribe to anything its client could not have opened directly.
    if (action === "subscribe" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      let sub;
      try {
        sub = JSON.parse(body);
      } catch (_) {
        return new Response("Malformed body", { status: 400 });
      }
      if (typeof sub.hub !== "string" || !/^hub_[A-Za-z0-9_=-]+$/.test(sub.hub)) {
        return new Response("Malformed body", { status: 400 });
      }
      const ok = await verifySignature(
        address,
        sub.sig,
        sub.ts,
        `SUB${address}${sub.ts}`,
      );
      if (!ok) return unauthorized();

      const token = await this.addSubscriber(sub.hub);
      if (!token) return new Response("Too many subscribers", { status: 507 });
      return json({ token });
    }

    // A hub relaying a frame its client sent. Authorised by the token the
    // subscribe above handed out, so only a hub that proved the mailbox key
    // can publish into it.
    if (action === "publish" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      const hub = await this.subscriberForToken(request.headers.get("X-Hub-Token"));
      if (!hub) return unauthorized();

      const queued = await this.deliver(body, { fromHub: hub.hub });
      return queued ? new Response("OK") : new Response("Mailbox full", { status: 507 });
    }

    // A client on another relay dropping mail into this mailbox. Signed by the
    // mailbox key, which both participants can derive, so this needs no
    // subscription here — it is how federation works: you listen on your own
    // relay, and send to your contact's.
    if (action === "post" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();
      const queued = await this.deliver(body);
      return queued ? new Response("OK") : new Response("Mailbox full", { status: 507 });
    }

    if (action === "unsubscribe" && request.method === "POST") {
      const hub = await this.subscriberForToken(request.headers.get("X-Hub-Token"));
      if (!hub) return unauthorized();
      await this.removeSubscriber(hub.hub);
      return new Response("OK");
    }

    // Where to knock when mail arrives and nobody is listening. The body is
    // either a UnifiedPush endpoint URL or `apns:<device token>`; an empty
    // `url` clears it. Signed by the mailbox key like everything else.
    if (action === "wake" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();

      let wake;
      try {
        wake = JSON.parse(body);
      } catch (_) {
        return new Response("Malformed body", { status: 400 });
      }
      if (wake.url === null || wake.url === "") {
        await this.state.storage.delete("wake");
        return new Response("OK");
      }
      const check = validateWakeTarget(wake.url, this.env);
      if (check) return json({ error: check }, check.includes("configured") ? 501 : 400);

      await this.state.storage.put("wake", { url: wake.url, at: Date.now() });
      return new Response("OK");
    }

    if (action) return new Response("Method not allowed", { status: 405 });

    // Direct WebSocket upgrade — the v2 path, kept for older clients.
    // Signature travels as query parameters because the WebSocket API cannot
    // set request headers portably.
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    if (!(await this.verifyQueryAuth(url, address))) return unauthorized();

    const [client, server] = Object.values(new WebSocketPair());
    server.serializeAttachment({ kind: "mbx" });
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  // ── Hub ────────────────────────────────────────────────────────────────────

  async handleHub(request, url, hubId, action) {
    // A mailbox delivering to this hub's client. The token proves the mailbox
    // is one this hub subscribed to; without it anyone who guessed a hub id
    // could inject frames.
    if (action === "deliver" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      let frame;
      try {
        frame = JSON.parse(body);
      } catch (_) {
        return new Response("Malformed body", { status: 400 });
      }
      const subs = (await this.state.storage.get("hubSubs")) || {};
      const token = request.headers.get("X-Hub-Token");
      if (!token || subs[frame.a] !== token) return unauthorized();

      const sockets = this.state.getWebSockets();
      if (sockets.length === 0) {
        // Nobody here. Tell the mailbox so it stops trying and wakes instead.
        return new Response("Gone", { status: 410 });
      }
      let delivered = 0;
      const out = JSON.stringify({ t: "msg", a: frame.a, d: frame.d });
      for (const sock of sockets) {
        try {
          sock.send(out);
          delivered++;
        } catch (_) {}
      }
      return delivered > 0 ? new Response("OK") : new Response("Gone", { status: 410 });
    }

    if (action) return new Response("Method not allowed", { status: 405 });

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const [client, server] = Object.values(new WebSocketPair());
    server.serializeAttachment({ kind: "hub", id: hubId });
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Frames from the client over the hub socket. */
  async hubMessage(ws, hubId, raw) {
    let frame;
    try {
      frame = JSON.parse(typeof raw === "string" ? raw : arrayBufferToBase64(raw));
    } catch (_) {
      ws.send(JSON.stringify({ t: "err", e: "malformed" }));
      return;
    }

    if (frame.t === "ping") {
      ws.send(JSON.stringify({ t: "pong" }));
      return;
    }

    const address = frame.a;
    if (typeof address !== "string" || !ADDRESS_RE.test(address)) {
      ws.send(JSON.stringify({ t: "err", a: address, e: "malformed" }));
      return;
    }
    const hubName = `hub_${hubId}`;

    if (frame.t === "sub") {
      const res = await room(this.env, `mbx_${address}`).fetch(
        `https://relay/mbx/${address}/subscribe`,
        {
          method: "POST",
          body: JSON.stringify({ hub: hubName, ts: String(frame.ts), sig: frame.sig }),
        },
      );
      if (res.status !== 200) {
        ws.send(JSON.stringify({ t: "err", a: address, e: res.status === 401 ? "unauthorized" : "refused" }));
        return;
      }
      const { token } = await res.json();
      const subs = (await this.state.storage.get("hubSubs")) || {};
      subs[address] = token;
      await this.state.storage.put("hubSubs", subs);
      ws.send(JSON.stringify({ t: "ok", a: address }));
      return;
    }

    if (frame.t === "pub") {
      const subs = (await this.state.storage.get("hubSubs")) || {};
      const token = subs[address];
      if (!token) {
        ws.send(JSON.stringify({ t: "err", a: address, e: "unsubscribed" }));
        return;
      }
      if (typeof frame.d !== "string" || frame.d.length > MAX_BODY_BYTES) {
        ws.send(JSON.stringify({ t: "err", a: address, e: "too_large" }));
        return;
      }
      const res = await room(this.env, `mbx_${address}`).fetch(
        `https://relay/mbx/${address}/publish`,
        { method: "POST", headers: { "X-Hub-Token": token }, body: frame.d },
      );
      if (res.status === 401) {
        // The mailbox forgot us (TTL expired or it was reset). Drop the stale
        // token so the client resubscribes rather than retrying forever.
        delete subs[address];
        await this.state.storage.put("hubSubs", subs);
        ws.send(JSON.stringify({ t: "err", a: address, e: "unsubscribed" }));
        return;
      }
      if (res.status !== 200) {
        ws.send(JSON.stringify({ t: "err", a: address, e: res.status === 507 ? "full" : "refused" }));
        return;
      }
      if (frame.id !== undefined) {
        ws.send(JSON.stringify({ t: "sent", a: address, id: frame.id }));
      }
      return;
    }

    if (frame.t === "unsub") {
      const subs = (await this.state.storage.get("hubSubs")) || {};
      const token = subs[address];
      if (token) {
        delete subs[address];
        await this.state.storage.put("hubSubs", subs);
        await room(this.env, `mbx_${address}`).fetch(
          `https://relay/mbx/${address}/unsubscribe`,
          { method: "POST", headers: { "X-Hub-Token": token } },
        );
      }
      ws.send(JSON.stringify({ t: "ok", a: address }));
      return;
    }

    ws.send(JSON.stringify({ t: "err", a: address, e: "unknown" }));
  }

  /** The client left. Release every mailbox subscription it held. */
  async hubClosed() {
    if (this.state.getWebSockets().length > 0) return;
    const subs = (await this.state.storage.get("hubSubs")) || {};
    await this.state.storage.delete("hubSubs");
    const releases = Object.entries(subs).map(([address, token]) =>
      room(this.env, `mbx_${address}`)
        .fetch(`https://relay/mbx/${address}/unsubscribe`, {
          method: "POST",
          headers: { "X-Hub-Token": token },
        })
        .catch(() => {}),
    );
    await Promise.all(releases);
  }

  // ── Subscribers ────────────────────────────────────────────────────────────

  async addSubscriber(hub) {
    let token = null;
    await this.state.storage.transaction(async (txn) => {
      let subs = (await txn.get("subs")) || [];
      const cutoff = Date.now() - SUBSCRIPTION_TTL_MS;
      subs = subs.filter((s) => s.at > cutoff && s.hub !== hub);
      if (subs.length >= MAX_SUBSCRIBERS) return;
      token = crypto.randomUUID();
      subs.push({ hub, token, at: Date.now() });
      await txn.put("subs", subs);
    });
    return token;
  }

  async removeSubscriber(hub) {
    await this.state.storage.transaction(async (txn) => {
      const subs = (await txn.get("subs")) || [];
      await txn.put("subs", subs.filter((s) => s.hub !== hub));
    });
  }

  async subscriberForToken(token) {
    if (!token) return null;
    const subs = (await this.state.storage.get("subs")) || [];
    const cutoff = Date.now() - SUBSCRIPTION_TTL_MS;
    return subs.find((s) => s.token === token && s.at > cutoff) || null;
  }

  // ── Handshake inbox ────────────────────────────────────────────────────────

  async handleInbox(request, url, address, action) {
    // Unauthenticated write: a stranger sending a contact request.
    if (!action && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      const queued = await this.queue(body);
      return queued ? new Response("OK") : new Response("Mailbox full", { status: 507 });
    }

    // Authenticated read: only the identity that owns this inbox.
    if (action === "sync" && request.method === "GET") {
      if (!(await this.verifyAuth(request, address, ""))) return unauthorized();
      return json(await this.pending());
    }

    if (action === "ack" && request.method === "POST") {
      const body = await this.readBody(request);
      if (body === null) return tooLarge();
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();

      let ids;
      try {
        ids = JSON.parse(body).ids;
      } catch (_) {
        return new Response("Malformed body", { status: 400 });
      }
      if (!Array.isArray(ids)) return new Response("Malformed body", { status: 400 });

      await this.state.storage.transaction(async (txn) => {
        const pending = (await txn.get("mailbox")) || [];
        await txn.put("mailbox", pending.filter((m) => !ids.includes(m.id)));
      });
      return new Response("OK");
    }

    return new Response("Method not allowed", { status: 405 });
  }

  // ── Media blobs ────────────────────────────────────────────────────────────

  async handleBlob(request, address, indexRaw) {
    const index = parseInt(indexRaw, 10);
    if (!Number.isInteger(index) || index < 0 || index >= MAX_BLOB_CHUNKS) {
      return new Response("Bad chunk index", { status: 400 });
    }

    if (request.method === "GET") {
      const chunk = await this.state.storage.get(`chunk_${index}`);
      if (!chunk) return new Response(null, { status: 404 });
      await this.touchBlob();
      return new Response(chunk, {
        headers: { "Content-Type": "application/octet-stream" },
      });
    }

    if (request.method === "PUT") {
      const body = await this.readBody(request, MAX_BLOB_CHUNK_BYTES);
      if (body === null) return tooLarge();
      // Signed by the blob address, which the uploader derived when minting it.
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();

      const existing = await this.state.storage.get(`chunk_${index}`);
      if (existing) return new Response("Chunk already written", { status: 409 });

      // A per-blob byte cap, so the chunk count limit cannot be turned into
      // 1,400 maximal chunks of something that is not a 64 MB video.
      const used = (await this.state.storage.get("blobBytes")) || 0;
      if (used + body.length > MAX_BLOB_BYTES) {
        return new Response("Blob too large", { status: 413 });
      }

      await this.state.storage.put(`chunk_${index}`, body);
      await this.state.storage.put("blobBytes", used + body.length);
      await this.touchBlob();
      return new Response("OK");
    }

    return new Response("Method not allowed", { status: 405 });
  }

  /// Record last use so the retention alarm can expire idle blobs.
  async touchBlob() {
    await this.state.storage.put("blobTouched", Date.now());
    await this.scheduleSweep();
  }

  // ── Prekey bundle ──────────────────────────────────────────────────────────

  async handlePrekey(request, address) {
    if (request.method === "GET") {
      const data = await this.state.storage.get("prekey");
      if (!data) return new Response(null, { status: 404 });
      return new Response(data, { headers: { "Content-Type": "application/json" } });
    }

    if (request.method === "POST") {
      const body = await this.readBody(request, MAX_PREKEY_BYTES);
      if (body === null) return tooLarge();
      // The address is the owner's identity key, so only they can publish here.
      if (!(await this.verifyAuth(request, address, body))) return unauthorized();
      await this.state.storage.put("prekey", body);
      return new Response("OK");
    }

    return new Response("Method not allowed", { status: 405 });
  }

  // ── Sockets ────────────────────────────────────────────────────────────────

  async webSocketMessage(ws, message) {
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.kind === "hub") {
      return this.hubMessage(ws, attachment.id, message);
    }

    // Direct mailbox socket (v2 path).
    const payload =
      typeof message === "string" ? message : arrayBufferToBase64(message);
    await this.deliver(payload, { fromSocket: ws });
  }

  async webSocketClose(ws) {
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.kind === "hub") await this.hubClosed();
  }

  async webSocketError(ws) {
    const attachment = ws.deserializeAttachment() || {};
    if (attachment.kind === "hub") await this.hubClosed();
  }

  // ── Delivery ───────────────────────────────────────────────────────────────

  /**
   * Fan a payload out to every listener except its origin, queue it, and if
   * nobody was listening, knock on the registered wake endpoint.
   *
   * Always queue. Live delivery is a latency optimisation, not the guarantee.
   *
   * v5 queued only when no other socket was open, which had two failure
   * modes and both lost messages outright. A mailbox is shared by the two
   * parties, so the check could not tell the recipient's socket from a stale
   * one belonging to the sender — and a hibernatable socket outlives an app
   * that was killed or swiped away. It also raced: a message sent in the
   * moment before the relay noticed the recipient had gone was counted as
   * delivered to a socket that would never read it.
   *
   * The cost is that a message delivered live still sits here until the
   * recipient's next sync acknowledges it, so it is fetched once more and
   * discarded. Every receive path already discards by message id, so a
   * duplicate is invisible; a lost message is not.
   */
  async deliver(payload, { fromSocket = null, fromHub = null } = {}) {
    let listeners = 0;

    for (const sock of this.state.getWebSockets()) {
      if (sock === fromSocket) continue;
      try {
        sock.send(payload);
        listeners++;
      } catch (_) {}
    }

    const subs = (await this.state.storage.get("subs")) || [];
    const cutoff = Date.now() - SUBSCRIPTION_TTL_MS;
    const gone = [];
    const address = this.addressFromName();
    const pushes = subs
      .filter((s) => s.hub !== fromHub && s.at > cutoff)
      .map(async (s) => {
        try {
          const res = await room(this.env, s.hub).fetch(
            `https://relay/hub/${s.hub.slice(4)}/deliver`,
            {
              method: "POST",
              headers: { "X-Hub-Token": s.token },
              body: JSON.stringify({ a: address, d: payload }),
            },
          );
          if (res.status === 200) listeners++;
          else if (res.status === 410 || res.status === 401) gone.push(s.hub);
        } catch (_) {}
      });
    await Promise.all(pushes);

    if (gone.length > 0) {
      await this.state.storage.transaction(async (txn) => {
        const current = (await txn.get("subs")) || [];
        await txn.put("subs", current.filter((s) => !gone.includes(s.hub)));
      });
    }

    const queued = await this.queue(payload);

    if (queued && listeners === 0) {
      await this.maybeWake();
    }
    return queued;
  }

  /** The mailbox address, recovered from the object's own name. */
  addressFromName() {
    const name = this.state.id.name || "";
    return name.replace(/^mbx_/, "");
  }

  /**
   * Knock on the wake endpoint, if there is one, at most once per
   * coalescing window. The knock carries nothing: the device wakes, syncs
   * over its own authenticated connection, and decides locally whether to
   * show anything.
   */
  async maybeWake() {
    const wake = await this.state.storage.get("wake");
    if (!wake) return;
    if (Date.now() - wake.at > WAKE_TTL_MS) {
      await this.state.storage.delete("wake");
      return;
    }
    const last = (await this.state.storage.get("lastWake")) || 0;
    if (Date.now() - last < WAKE_COALESCE_MS) return;
    await this.state.storage.put("lastWake", Date.now());

    const task = sendWake(wake.url, this.env).catch((e) =>
      console.error("Wake failed:", e && e.message),
    );
    if (this.state.waitUntil) this.state.waitUntil(task);
    else await task;
  }

  async pending() {
    const mailbox = (await this.state.storage.get("mailbox")) || [];
    const cutoff = Date.now() - RETENTION_MS;
    return mailbox.filter((m) => m.ts > cutoff);
  }

  /** Append to the mailbox, enforcing count and byte quotas. */
  async queue(payload) {
    if (payload.length > MAX_BODY_BYTES) return false;

    let accepted = true;
    await this.state.storage.transaction(async (txn) => {
      let mailbox = (await txn.get("mailbox")) || [];
      const cutoff = Date.now() - RETENTION_MS;
      mailbox = mailbox.filter((m) => m.ts > cutoff);

      const used = mailbox.reduce((sum, m) => sum + (m.data?.length || 0), 0);
      if (used + payload.length > MAX_MAILBOX_BYTES) {
        accepted = false;
        return;
      }

      mailbox.push({ id: crypto.randomUUID(), data: payload, ts: Date.now() });
      if (mailbox.length > MAX_MAILBOX_MESSAGES) {
        mailbox = mailbox.slice(-MAX_MAILBOX_MESSAGES);
      }
      await txn.put("mailbox", mailbox);
    });
    return accepted;
  }

  // ── Retention ──────────────────────────────────────────────────────────────

  /**
   * Expire old mail on a timer rather than only when something is written.
   *
   * v1 pruned inside the write path only, so a mailbox that stopped receiving
   * kept its contents indefinitely — while the README claimed five minutes.
   */
  async scheduleSweep() {
    const existing = await this.state.storage.getAlarm();
    if (existing === null) {
      await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
  }

  async alarm() {
    // Blobs expire on the same clock as mail: once nothing has read or written
    // them for the retention window, the whole object is dropped.
    const touched = await this.state.storage.get("blobTouched");
    if (touched !== undefined) {
      if (Date.now() - touched > RETENTION_MS) {
        await this.state.storage.deleteAll();
        return;
      }
      await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
      return;
    }

    const mailbox = (await this.state.storage.get("mailbox")) || [];
    const cutoff = Date.now() - RETENTION_MS;
    const kept = mailbox.filter((m) => m.ts > cutoff);

    if (kept.length === 0) {
      await this.state.storage.delete("mailbox");
    } else if (kept.length !== mailbox.length) {
      await this.state.storage.put("mailbox", kept);
    }

    // Subscriptions and wake registrations age out on the same sweep.
    const subs = await this.state.storage.get("subs");
    if (Array.isArray(subs)) {
      const live = subs.filter((s) => s.at > Date.now() - SUBSCRIPTION_TTL_MS);
      if (live.length === 0) await this.state.storage.delete("subs");
      else if (live.length !== subs.length) await this.state.storage.put("subs", live);
    }
    const wake = await this.state.storage.get("wake");
    if (wake && Date.now() - wake.at > WAKE_TTL_MS) {
      await this.state.storage.delete("wake");
    }

    // Keep sweeping while anything remains; otherwise let the object go idle.
    const remaining = kept.length > 0 || (await this.state.storage.get("subs")) || (await this.state.storage.get("wake"));
    if (remaining) {
      await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
    }
  }

  // ── Plumbing ───────────────────────────────────────────────────────────────

  async underRateLimit() {
    const now = Date.now();
    const bucket = (await this.state.storage.get("rate")) || { start: now, count: 0 };

    if (now - bucket.start > RATE_WINDOW_MS) {
      bucket.start = now;
      bucket.count = 0;
    }
    bucket.count++;
    await this.state.storage.put("rate", bucket);
    return bucket.count <= MAX_REQUESTS_PER_WINDOW;
  }

  async readBody(request, limit = MAX_BODY_BYTES) {
    const declared = request.headers.get("Content-Length");
    if (declared && parseInt(declared, 10) > limit) return null;
    const body = await request.text();
    return body.length > limit ? null : body;
  }

  async verifyAuth(request, addressB64Url, body) {
    return verifyRequestAuth(request, addressB64Url, body);
  }

  /** Same, for WebSocket upgrades, which cannot carry custom headers. */
  async verifyQueryAuth(url, addressB64Url) {
    const sigHex = url.searchParams.get("sig");
    const tsStr = url.searchParams.get("ts");
    if (!sigHex || !tsStr) return false;

    const message = `WS${url.pathname}${tsStr}`;
    return verifySignature(addressB64Url, sigHex, tsStr, message);
  }
}

// ── Wake (push) ──────────────────────────────────────────────────────────────

/**
 * A wake target is a UnifiedPush endpoint (any https URL) or an APNs device
 * token written as `apns:<hex>`. Returns an error string or null.
 */
function validateWakeTarget(url, env) {
  if (typeof url !== "string" || url.length > 2048) return "Malformed wake target";
  if (url.startsWith("apns:")) {
    if (!/^apns:[0-9a-fA-F]{32,200}$/.test(url)) return "Malformed APNs token";
    if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) {
      return "APNs is not configured on this relay";
    }
    return null;
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch (_) {
    return "Malformed wake target";
  }
  if (parsed.protocol !== "https:") return "Wake target must be https";
  return null;
}

async function sendWake(url, env) {
  if (url.startsWith("apns:")) {
    return sendApns(url.slice(5), env);
  }
  // UnifiedPush: an empty POST is a valid, content-free wake. The distributor
  // learns that *this endpoint* was poked and when; nothing else.
  await fetch(url, { method: "POST", body: "", headers: { "TTL": "86400", "Urgency": "high" } });
}

/**
 * Background push through APNs with a provider token (ES256 JWT). No alert,
 * no body: `content-available` only, so the device wakes and syncs.
 */
async function sendApns(deviceToken, env) {
  const host = env.APNS_HOST || "api.push.apple.com";
  const jwt = await apnsJwt(env);
  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "background",
      "apns-priority": "5",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps: { "content-available": 1 } }),
  });
  if (res.status !== 200) {
    const text = await res.text().catch(() => "");
    throw new Error(`APNs ${res.status} ${text}`);
  }
}

async function apnsJwt(env) {
  const header = { alg: "ES256", kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) };
  const enc = (obj) => bytesToBase64Url(new TextEncoder().encode(JSON.stringify(obj)));
  const signingInput = `${enc(header)}.${enc(claims)}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(sig))}`;
}

// ── Auth ─────────────────────────────────────────────────────────────────────

/**
 * Verify an Ed25519 signature over METHOD + path + body + timestamp,
 * against the address in the path.
 */
async function verifyRequestAuth(request, addressB64Url, body) {
  const sigHex = request.headers.get("X-Spheres-Signature");
  const tsStr = request.headers.get("X-Spheres-Timestamp");
  if (!sigHex || !tsStr) return false;

  const url = new URL(request.url);
  const message = `${request.method}${url.pathname}${body}${tsStr}`;
  return verifySignature(addressB64Url, sigHex, tsStr, message);
}

async function verifySignature(addressB64Url, sigHex, tsStr, message) {
  try {
    const ts = parseInt(tsStr, 10);
    if (!Number.isFinite(ts)) return false;
    if (Math.abs(Date.now() - ts) > AUTH_WINDOW_MS) return false;

    const keyBytes = base64UrlToBytes(addressB64Url);
    if (keyBytes.length !== 32) return false;

    const sigBytes = hexToBytes(sigHex);
    if (sigBytes.length !== 64) return false;

    const key = await crypto.subtle.importKey(
      "raw",
      keyBytes,
      { name: "Ed25519" },
      false,
      ["verify"],
    );

    return await crypto.subtle.verify(
      "Ed25519",
      key,
      sigBytes,
      new TextEncoder().encode(message),
    );
  } catch (e) {
    // Do not swallow this silently: if Ed25519 is unavailable under the
    // configured compatibility date, every request 401s and the only symptom
    // is clients reporting Unauthorized.
    console.error("Signature verification failed:", e && e.message);
    return false;
  }
}

function unauthorized() {
  return new Response("Unauthorized", { status: 401 });
}

function tooLarge() {
  return new Response("Payload too large", { status: 413 });
}

// ── Encoding ─────────────────────────────────────────────────────────────────

function hexToBytes(hex) {
  if (typeof hex !== "string" || hex.length % 2 !== 0) return new Uint8Array(0);
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const byte = parseInt(hex.substr(i * 2, 2), 16);
    if (Number.isNaN(byte)) return new Uint8Array(0);
    out[i] = byte;
  }
  return out;
}

function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(padded);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function bytesToBase64(bytes) {
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

function bytesToBase64Url(bytes) {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBytes(pem) {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  return base64UrlToBytes(body.replace(/\+/g, "-").replace(/\//g, "_"));
}

/**
 * Chunked so a large binary frame cannot blow the call stack.
 *
 * v1 did btoa(String.fromCharCode(...new Uint8Array(message))), which spreads
 * every byte as an argument — a ~100KB voice note threw RangeError inside the
 * storage transaction, so the message was silently never queued.
 */
function arrayBufferToBase64(buffer) {
  return bytesToBase64(new Uint8Array(buffer));
}
