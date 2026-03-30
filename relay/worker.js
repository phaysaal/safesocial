/**
 * Spheres Relay — Cloudflare Worker
 *
 * Zero-knowledge message relay and state sync. Passes encrypted blobs.
 * No auth, no logs.
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/") {
      return new Response(JSON.stringify({
        service: "Spheres Relay",
        status: "ok",
        version: "3.0",
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // State Sync Endpoint (replaces DHT)
    // /state/<pubkey>/<key>
    const stateMatch = url.pathname.match(/^\/state\/([a-zA-Z0-9_-]+)\/([a-zA-Z0-9_-]+)$/);
    if (stateMatch) {
      // Use a separate DO or just the same room DO but keyed by pubkey
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
      const key = parts[3]; // /state/pubkey/key
      
      if (request.method === 'GET') {
        const data = await this.state.storage.get(`state_${key}`);
        if (!data) return new Response(null, { status: 404 });
        return new Response(data, { 
          headers: { 'Content-Type': 'application/json' }
        });
      }
      
      if (request.method === 'POST') {
        const data = await request.text();
        await this.state.storage.put(`state_${key}`, data);
        return new Response('OK', { status: 200 });
      }
      return new Response('Method not allowed', { status: 405 });
    }

    // --- HTTP MAILBOX SYNC LOGIC ---
    if (url.pathname.endsWith('/sync') && request.method === 'GET') {
      const pending = await this.state.storage.get("mailbox") || [];
      return new Response(JSON.stringify(pending), {
        headers: { 'Content-Type': 'application/json' }
      });
    }

    if (url.pathname.endsWith('/ack') && request.method === 'POST') {
      const { ids } = await request.json();
      let pending = await this.state.storage.get("mailbox") || [];
      pending = pending.filter(m => !ids.includes(m.id));
      await this.state.storage.put("mailbox", pending);
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
    
    // Attempt real-time delivery
    for (const sock of sockets) {
      if (sock !== ws) {
        try {
          sock.send(message);
          delivered = true;
        } catch (_) {}
      }
    }

    // If offline, store in mailbox (30 days TTL, max 1000)
    if (!delivered) {
      const pending = await this.state.storage.get("mailbox") || [];
      
      pending.push({
        id: crypto.randomUUID(),
        data: typeof message === 'string' ? message : btoa(String.fromCharCode(...new Uint8Array(message))),
        ts: Date.now(),
      });

      const cutoff = Date.now() - 30 * 24 * 60 * 60 * 1000;
      const filtered = pending.filter(m => m.ts > cutoff).slice(-1000);
      
      await this.state.storage.put("mailbox", filtered);
    }
  }

  async webSocketClose(ws, code, reason, wasClean) {}
  async webSocketError(ws, error) {}
}
