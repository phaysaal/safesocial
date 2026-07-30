/**
 * Spheres Relay v2 — Cloudflare Worker
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
 * What the operator can still see: message sizes (bucketed by the client),
 * timing, and that some address is active. Removing those needs padding
 * schedules and cover traffic, which are not implemented.
 */

const VERSION = "5.0";

// ── Limits ───────────────────────────────────────────────────────────────────
// v1 had none of these: unlimited body size, unlimited keys per identity, and
// unlimited Durable Objects mintable by anyone.
const MAX_BODY_BYTES = 256 * 1024;
const MAX_MAILBOX_MESSAGES = 500;
const MAX_MAILBOX_BYTES = 8 * 1024 * 1024;
const MAX_PREKEY_BYTES = 4 * 1024;

// Blob storage for media. Chunked because a Durable Object storage value tops
// out at 128 KiB, and base64 inflates by 4/3.
const MAX_BLOB_CHUNK_BYTES = 96 * 1024;
const MAX_BLOB_CHUNKS = 512;
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const SWEEP_INTERVAL_MS = 6 * 60 * 60 * 1000;
const AUTH_WINDOW_MS = 5 * 60 * 1000;

// Rate limiting, per Durable Object.
const RATE_WINDOW_MS = 60 * 1000;
const MAX_REQUESTS_PER_WINDOW = 120;

/** 32-byte key encoded base64url — the shape of every address we accept. */
const ADDRESS_RE = /^[A-Za-z0-9_-]{43}=?$/;

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return json({ service: "Spheres Relay", status: "blind", version: VERSION });
    }

    // Sealed mailbox: /mbx/<address>[/sync|/ack]
    // Address is an Ed25519 public key derived from a shared secret. Every
    // operation, including the WebSocket upgrade, must be signed by it.
    const mbx = url.pathname.match(/^\/mbx\/([A-Za-z0-9_=-]+)(?:\/(sync|ack))?$/);
    if (mbx) {
      if (!ADDRESS_RE.test(mbx[1])) {
        return new Response("Malformed mailbox address", { status: 400 });
      }
      return env.RELAY_ROOM.get(env.RELAY_ROOM.idFromName(`mbx_${mbx[1]}`)).fetch(request);
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
      return env.RELAY_ROOM.get(env.RELAY_ROOM.idFromName(`inbox_${inbox[1]}`)).fetch(request);
    }

    // Media blob: /blob/<address>/<chunk index>
    // The address is a 256-bit capability that only travels inside sealed
    // envelopes, and the bytes are encrypted before they arrive. Reads are
    // therefore unauthenticated — holding the address is the authorisation —
    // while writes are signed, so a blob cannot be overwritten by a passer-by.
    const blob = url.pathname.match(/^\/blob\/([A-Za-z0-9_=-]+)\/(\d{1,3})$/);
    if (blob) {
      if (!ADDRESS_RE.test(blob[1])) {
        return new Response("Malformed blob address", { status: 400 });
      }
      return env.RELAY_ROOM.get(env.RELAY_ROOM.idFromName(`blob_${blob[1]}`)).fetch(request);
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
      return env.RELAY_ROOM.get(env.RELAY_ROOM.idFromName(`prekey_${prekey[1]}`)).fetch(request);
    }

    return new Response("Not found.", { status: 404 });
  },
};

export class RelayRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const segments = url.pathname.split("/").filter(Boolean);
    const kind = segments[0]; // mbx | inbox | prekey
    const address = segments[1];
    const action = segments[2];

    if (!(await this.underRateLimit())) {
      return new Response("Too many requests", { status: 429 });
    }

    await this.scheduleSweep();

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

    if (action) return new Response("Method not allowed", { status: 405 });

    // WebSocket upgrade. Signature travels as query parameters because the
    // WebSocket API cannot set request headers portably.
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }
    if (!(await this.verifyQueryAuth(url, address))) return unauthorized();

    const [client, server] = Object.values(new WebSocketPair());
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
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

      await this.state.storage.put(`chunk_${index}`, body);
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

  // ── Delivery ───────────────────────────────────────────────────────────────

  async webSocketMessage(ws, message) {
    const payload =
      typeof message === "string" ? message : arrayBufferToBase64(message);

    const sockets = this.state.getWebSockets();
    let delivered = false;
    for (const sock of sockets) {
      if (sock === ws) continue;
      try {
        sock.send(message);
        delivered = true;
      } catch (_) {}
    }

    // Only queue when nobody was listening. Note this counts *any* other
    // socket on the mailbox as delivery — acceptable now that reaching a
    // mailbox requires its key, which v1 did not.
    if (!delivered) await this.queue(payload);
  }

  async webSocketClose() {}
  async webSocketError() {}

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

    // Keep sweeping while anything remains; otherwise let the object go idle.
    if (kept.length > 0) {
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

  /**
   * Verify an Ed25519 signature over METHOD + path + body + timestamp,
   * against the address in the path.
   */
  async verifyAuth(request, addressB64Url, body) {
    const sigHex = request.headers.get("X-Spheres-Signature");
    const tsStr = request.headers.get("X-Spheres-Timestamp");
    if (!sigHex || !tsStr) return false;

    const url = new URL(request.url);
    const message = `${request.method}${url.pathname}${body}${tsStr}`;
    return this.verifySignature(addressB64Url, sigHex, tsStr, message);
  }

  /** Same, for WebSocket upgrades, which cannot carry custom headers. */
  async verifyQueryAuth(url, addressB64Url) {
    const sigHex = url.searchParams.get("sig");
    const tsStr = url.searchParams.get("ts");
    if (!sigHex || !tsStr) return false;

    const message = `WS${url.pathname}${tsStr}`;
    return this.verifySignature(addressB64Url, sigHex, tsStr, message);
  }

  async verifySignature(addressB64Url, sigHex, tsStr, message) {
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
}

function unauthorized() {
  return new Response("Unauthorized", { status: 401 });
}

function tooLarge() {
  return new Response("Payload too large", { status: 413 });
}

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

/**
 * Chunked so a large binary frame cannot blow the call stack.
 *
 * v1 did btoa(String.fromCharCode(...new Uint8Array(message))), which spreads
 * every byte as an argument — a ~100KB voice note threw RangeError inside the
 * storage transaction, so the message was silently never queued.
 */
function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}
