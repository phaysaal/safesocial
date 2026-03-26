/**
 * Spheres Relay — Cloudflare Worker WebSocket relay
 *
 * A zero-knowledge message relay for Spheres P2P social network.
 * Passes encrypted blobs between peers. No auth, no logs, no storage.
 *
 * Protocol:
 *   1. Client connects: wss://relay.spheres.dev/room/<room_id>
 *   2. room_id = SHA256(sorted(publicKeyA, publicKeyB))[:16]
 *   3. Messages sent by one client are forwarded to all others in the room
 *   4. Undelivered messages held in memory for 5 minutes max
 *
 * Deploy: npx wrangler deploy
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/") {
      return new Response(JSON.stringify({
        service: "Spheres Relay",
        status: "ok",
        rooms: env.ROOMS ? "durable_objects" : "in_memory",
      }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // WebSocket upgrade for /room/<id>
    const match = url.pathname.match(/^\/room\/([a-zA-Z0-9_-]+)$/);
    if (!match) {
      return new Response("Not found. Use /room/<room_id>", { status: 404 });
    }

    const upgradeHeader = request.headers.get("Upgrade");
    if (!upgradeHeader || upgradeHeader !== "websocket") {
      return new Response("Expected WebSocket", { status: 426 });
    }

    const roomId = match[1];

    // Use Durable Objects for room state
    const id = env.RELAY_ROOM.idFromName(roomId);
    const room = env.RELAY_ROOM.get(id);
    return room.fetch(request);
  },
};

/**
 * Durable Object: one per room. Manages WebSocket connections
 * and message forwarding within a room.
 */
export class RelayRoom {
  constructor(state, env) {
    this.state = state;
    this.connections = new Set();
    this.pendingMessages = []; // Messages waiting for the other peer
    this.lastActivity = Date.now();

    // Clean up pending messages older than 5 minutes
    this.cleanupInterval = setInterval(() => {
      const cutoff = Date.now() - 5 * 60 * 1000;
      this.pendingMessages = this.pendingMessages.filter(m => m.ts > cutoff);
    }, 60000);
  }

  async fetch(request) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.state.acceptWebSocket(server);
    this.connections.add(server);
    this.lastActivity = Date.now();

    // Deliver any pending messages to the new connection
    for (const msg of this.pendingMessages) {
      try {
        server.send(msg.data);
      } catch (_) {}
    }
    this.pendingMessages = [];

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    this.lastActivity = Date.now();

    // Forward to all OTHER connections in the room
    let delivered = false;
    for (const conn of this.connections) {
      if (conn !== ws) {
        try {
          conn.send(message);
          delivered = true;
        } catch (_) {
          this.connections.delete(conn);
        }
      }
    }

    // If no one else is connected, queue the message (5 min TTL)
    if (!delivered) {
      this.pendingMessages.push({
        data: message,
        ts: Date.now(),
      });

      // Cap at 100 pending messages per room
      if (this.pendingMessages.length > 100) {
        this.pendingMessages.shift();
      }
    }
  }

  async webSocketClose(ws, code, reason) {
    this.connections.delete(ws);
  }

  async webSocketError(ws, error) {
    this.connections.delete(ws);
  }
}
