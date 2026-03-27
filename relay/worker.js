/**
 * Spheres Relay — Cloudflare Worker WebSocket relay
 *
 * Zero-knowledge message relay. Passes encrypted blobs between peers.
 * No auth, no logs, no storage.
 *
 * Protocol:
 *   1. Client connects: wss://relay.spheres.dev/room/<room_id>
 *   2. Messages from one client are forwarded to all others in the room
 *   3. Undelivered messages held in memory for 5 minutes max
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === "/") {
      return new Response(JSON.stringify({
        service: "Spheres Relay",
        status: "ok",
        version: "2.0",
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
    const id = env.RELAY_ROOM.idFromName(roomId);
    const room = env.RELAY_ROOM.get(id);
    return room.fetch(request);
  },
};

/**
 * Durable Object: one per room.
 * Uses the WebSocket Hibernation API so connections survive DO sleep cycles.
 */
export class RelayRoom {
  constructor(state, env) {
    this.state = state;
  }

  async fetch(request) {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    // Accept the WebSocket with hibernation support
    this.state.acceptWebSocket(server);

    // Deliver any pending messages from storage
    const pending = await this.state.storage.get("pending") || [];
    for (const msg of pending) {
      try {
        server.send(msg.data);
      } catch (_) {}
    }
    // Clear pending after delivery
    if (pending.length > 0) {
      await this.state.storage.delete("pending");
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    // Get all connected WebSockets via the hibernation API
    const sockets = this.state.getWebSockets();

    let delivered = false;
    for (const sock of sockets) {
      if (sock !== ws) {
        try {
          sock.send(message);
          delivered = true;
        } catch (_) {
          // Dead socket — will be cleaned up by webSocketClose
        }
      }
    }

    // If no one else is connected, queue the message (max 50, 5 min TTL)
    if (!delivered) {
      const pending = await this.state.storage.get("pending") || [];
      pending.push({
        data: message,
        ts: Date.now(),
      });

      // Remove old messages (> 5 min) and cap at 50
      const cutoff = Date.now() - 5 * 60 * 1000;
      const filtered = pending.filter(m => m.ts > cutoff).slice(-50);
      await this.state.storage.put("pending", filtered);
    }
  }

  async webSocketClose(ws, code, reason, wasClean) {
    // Nothing to do — hibernation API handles cleanup
  }

  async webSocketError(ws, error) {
    // Nothing to do
  }
}
