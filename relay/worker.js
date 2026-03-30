/**
 * Spheres Relay — Cloudflare Worker
 *
 * Zero-knowledge message relay and state sync. Passes encrypted blobs.
 * Hardened with Ed25519 signature verification and atomic storage.
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/") {
      return new Response(JSON.stringify({
        service: "Spheres Relay",
        status: "hardened",
        version: "4.0",
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // State Sync Endpoint (replaces DHT)
    // /state/<pubkey>/<key>
    const stateMatch = url.pathname.match(/^\/state\/([a-zA-Z0-9_-]+)\/([a-zA-Z0-9_-]+)$/);
    if (stateMatch) {
      const pubkey = stateMatch[1];
      const id = env.RELAY_ROOM.idFromName(`state_${pubkey}`);
      const room = env.RELAY_ROOM.get(id);
      return room.fetch(request);
    }

    // Room endpoints (WebSocket or HTTP Sync)
    const roomMatch = url.pathname.match(/^\/room\/([a-zA-Z0-9_-]+)(?:\/(sync|ack))?$/);
    if (!roomMatch) {
      return new Response("Not found.", { status: 404 });
    }

    const roomId = roomMatch[1];
    const id = env.RELAY_ROOM.idFromName(roomId);
    const room = env.RELAY_ROOM.get(id);
    return room.fetch(request);
  },
};

/**
 * Durable Object: handles WebSockets, Offline Mailbox, and State Sync.
 */
export class RelayRoom {
  constructor(state, env) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);

    // --- STATE SYNC LOGIC ---
    if (url.pathname.startsWith('/state/')) {
      const parts = url.pathname.split('/');
      const ownerPubKey = parts[2];
      const key = parts[3];
      
      if (request.method === 'GET') {
        const data = await this.state.storage.get(`state_${key}`);
        if (!data) return new Response(null, { status: 404 });
        return new Response(data, { headers: { 'Content-Type': 'application/json' } });
      }
      
      if (request.method === 'POST') {
        // Authenticate the owner of this state
        const body = await request.text();
        const isValid = await this.verifyAuth(request, ownerPubKey, body);
        if (!isValid) return new Response('Unauthorized', { status: 401 });

        await this.state.storage.put(`state_${key}`, body);
        return new Response('OK', { status: 200 });
      }
      return new Response('Method not allowed', { status: 405 });
    }

    // --- HTTP MAILBOX SYNC LOGIC ---
    if (url.pathname.endsWith('/sync') && request.method === 'GET') {
      // Identity who is requesting their mailbox
      const requesterPubKey = request.headers.get('X-Spheres-PubKey');
      if (!requesterPubKey) return new Response('Missing X-Spheres-PubKey', { status: 400 });

      const isValid = await this.verifyAuth(request, requesterPubKey, "");
      if (!isValid) return new Response('Unauthorized', { status: 401 });

      const pending = await this.state.storage.get("mailbox") || [];
      return new Response(JSON.stringify(pending), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    if (url.pathname.endsWith('/ack') && request.method === 'POST') {
      const requesterPubKey = request.headers.get('X-Spheres-PubKey');
      if (!requesterPubKey) return new Response('Missing X-Spheres-PubKey', { status: 400 });

      const body = await request.text();
      const isValid = await this.verifyAuth(request, requesterPubKey, body);
      if (!isValid) return new Response('Unauthorized', { status: 401 });

      const { ids } = JSON.parse(body);
      
      // Use transaction for atomic mailbox update
      await this.state.storage.transaction(async (txn) => {
        let pending = await txn.get("mailbox") || [];
        pending = pending.filter(m => !ids.includes(m.id));
        await txn.put("mailbox", pending);
      });

      return new Response('OK', { status: 200 });
    }

    // --- WEBSOCKET LOGIC ---
    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server);

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const sockets = this.state.getWebSockets();
    let delivered = false;
    
    for (const sock of sockets) {
      if (sock !== ws) {
        try {
          sock.send(message);
          delivered = true;
        } catch (_) {}
      }
    }

    if (!delivered) {
      // Atomic queueing
      await this.state.storage.transaction(async (txn) => {
        const pending = await txn.get("mailbox") || [];
        pending.push({
          id: crypto.randomUUID(),
          data: typeof message === 'string' ? message : btoa(String.fromCharCode(...new Uint8Array(message))),
          ts: Date.now(),
        });
        const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
        const filtered = pending.filter(m => m.ts > cutoff).slice(-1000);
        await txn.put("mailbox", filtered);
      });
    }
  }

  async webSocketClose(ws, code, reason, wasClean) {}
  async webSocketError(ws, error) {}

  /**
   * Verifies Ed25519 signature of the request.
   * Format: signature(method + path + body + timestamp)
   */
  async verifyAuth(request, pubKeyHex, body) {
    try {
      const sigHex = request.headers.get('X-Spheres-Signature');
      const tsStr = request.headers.get('X-Spheres-Timestamp');
      if (!sigHex || !tsStr) return false;

      // 1. Replay protection (5 min window)
      const ts = parseInt(tsStr);
      if (Math.abs(Date.now() - ts) > 5 * 60 * 1000) return false;

      // 2. Construct message to verify
      const url = new URL(request.url);
      const message = `${request.method}${url.pathname}${body}${tsStr}`;
      const encoder = new TextEncoder();
      const messageBytes = encoder.encode(message);

      // 3. Import Public Key
      const pubKeyBytes = new Uint8Array(pubKeyHex.match(/.{1,2}/g).map(byte => parseInt(byte, 16)));
      const key = await crypto.subtle.importKey(
        'raw',
        pubKeyBytes,
        { name: 'Ed25519' },
        true,
        ['verify']
      );

      // 4. Verify Signature
      const sigBytes = new Uint8Array(sigHex.match(/.{1,2}/g).map(byte => parseInt(byte, 16)));
      return await crypto.subtle.verify(
        'Ed25519',
        key,
        sigBytes,
        messageBytes
      );
    } catch (e) {
      console.error('Auth verification error:', e);
      return false;
    }
  }
}
