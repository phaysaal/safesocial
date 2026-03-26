# Spheres Relay

Zero-knowledge WebSocket message relay for the Spheres P2P social network.

## What it does

Passes encrypted blobs between peers as a fallback when Veilid DHT is slow. The relay:

- **Sees nothing** — messages are end-to-end encrypted before reaching the relay
- **Stores nothing** — undelivered messages are held in memory for max 5 minutes
- **Logs nothing** — no access logs, no metadata, no IP tracking
- **Requires nothing** — no auth, no accounts, no API keys

## Deploy to Cloudflare Workers

```bash
cd relay
npm install
npx wrangler login        # One-time: authenticate with Cloudflare
npx wrangler deploy       # Deploy to workers.dev
```

After deployment, you'll get a URL like:
```
https://spheres-relay.YOUR_SUBDOMAIN.workers.dev
```

Update the `_defaultRelayUrl` in `relay_service.dart` with this URL.

## Custom domain

To use `relay.spheres.dev`, uncomment the routes section in `wrangler.toml` and configure DNS in Cloudflare.

## Protocol

1. Client connects: `wss://relay.spheres.dev/room/<room_id>`
2. `room_id` = deterministic hash of both peers' public keys (sorted)
3. Messages from one client are forwarded to the other
4. If the other peer isn't connected, messages queue for 5 minutes

## Cost

Cloudflare Workers free tier: 100,000 requests/day, 10ms CPU per request.
For a small user base, this is essentially free.
