# Spheres Relay (v3)

Blind store-and-forward relay for Spheres, running on Cloudflare Workers.

## What it does

Moves opaque bytes between addresses it cannot connect to any identity.

- **Cannot identify participants** — an address is an Ed25519 public key derived from a
  secret only the two participants share. The operator cannot compute it from public keys,
  so the social graph is not reconstructible from traffic.
- **Cannot read content** — payloads are sealed by the client before they arrive.
- **Cannot be talked into handing over mail** — access is granted by signing the request
  with the address's private key, verified against the address itself. There is no
  membership list to bypass.
- **Retains for 30 days** — undelivered mail expires on a timer, not only when something
  new is written.
- **Stores in one region** — Durable Objects are pinned to the EU jurisdiction by default
  (`DO_JURISDICTION` in `wrangler.toml`).

### What it can still see

Message sizes (bucketed by the client into 512B / 2K / 8K / 32K / 128K), timing, that
some address is active, and — through the hub — which addresses one client holds. Removing
those needs padding schedules and cover traffic, which are not implemented. Cloudflare
additionally sees IP addresses; the worker itself does not log them.

### v3: one socket per client

v2 opened one WebSocket per mailbox. A phone with thirty contacts held ninety sockets
(chat, feed and call channels each), each with its own reconnect loop and watchdog — on
mobile, ninety things that can silently die when the network changes.

v3 adds the **hub**: a Durable Object named by a random 256-bit id the client mints at
launch. The client opens one socket to it and subscribes to each mailbox over that socket
by signing `SUB<address><ts>` with the mailbox key — the same proof the direct upgrade
required. The hub forwards the subscription to the mailbox object, which verifies the
signature itself and hands back a token; publishes and deliveries between the two objects
carry that token. A hub never learns a key it was not shown a signature for, and a guessed
hub id yields nothing.

Direct per-mailbox sockets (`WS /mbx/<address>`) still work, so older clients are not cut
off, and both paths fan out to each other.

### Federation

Everyone listens on their own relay and sends to their contact's. A contact's relay host
travels in their signed prekey bundle; a client whose contact is on another relay drops
mail there with a signed `POST /mbx/<address>/post`. The other relay learns exactly what
this one would: an address and ciphertext.

## Endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `WS /hub/<client id>` | none (id is a capability) | One socket for all mailboxes |
| `WS /mbx/<address>?ts&sig` | signed by the mailbox key | Live delivery (v2 path) |
| `GET /mbx/<address>/sync` | signed by the mailbox key | Fetch queued mail |
| `POST /mbx/<address>/ack` | signed by the mailbox key | Delete fetched mail |
| `POST /mbx/<address>/post` | signed by the mailbox key | Drop mail in from another relay |
| `POST /mbx/<address>/wake` | signed by the mailbox key | Register a push wake target |
| `POST /mbx/<address>/subscribe` | signed `SUB` frame, via a hub | Hub subscription |
| `POST /mbx/<address>/publish` | subscription token, via a hub | Hub publish |
| `POST /mbx/<address>/unsubscribe` | subscription token, via a hub | Hub release |
| `POST /inbox/<identity>` | **none, by design** | Send a contact handshake |
| `GET /inbox/<identity>/sync` | signed by the identity key | Read your handshakes |
| `POST /inbox/<identity>/ack` | signed by the identity key | Clear handshakes |
| `PUT /blob/<address>/<n>` | signed by the blob address | Upload a media chunk |
| `GET /blob/<address>/<n>` | none | Fetch a media chunk |
| `GET /prekey/<identity>` | none | Fetch a public key bundle |
| `POST /prekey/<identity>` | signed by the identity key | Publish your key bundle |
| `GET /turn/<address>` | signed by any mailbox key | Short-lived TURN credentials |

Hub frames, client → hub: `{"t":"sub","a":address,"ts":ms,"sig":hex}`,
`{"t":"pub","a":address,"d":payload,"id":n}`, `{"t":"unsub","a":address}`, `{"t":"ping"}`.
Hub → client: `{"t":"ok","a"}`, `{"t":"msg","a","d"}`, `{"t":"sent","a","id"}`,
`{"t":"err","a","e":"unauthorized"|"unsubscribed"|"full"|"refused"}`, `{"t":"pong"}`.

Blob reads are unauthenticated because the address is a 256-bit capability that only
travels inside sealed envelopes, and the bytes are encrypted before they arrive. Writes are
signed so a blob cannot be overwritten by a passer-by, and a chunk that already exists
returns 409 rather than being replaced. Blobs expire on the same 30-day clock as mail,
counted from last use.

The handshake inbox is deliberately asymmetric: a stranger has no shared secret to sign
with, so writes are open, but only the owner can read what arrived. The prekey bundle is
public because a new contact needs your X25519 key before any shared secret can exist — it
contains your identity key, your device keys (each certified by the identity key), your
relay host, and a signature over all of it.

Signed requests carry `X-Spheres-Signature` (hex) and `X-Spheres-Timestamp` (ms) over
`METHOD + path + body + timestamp`, within a five-minute window. WebSocket upgrades pass
`sig` and `ts` as query parameters instead, over `WS + path + timestamp`, because the
WebSocket API cannot set request headers portably.

### Wake (push)

A mailbox can hold one wake target: a UnifiedPush endpoint URL, or `apns:<device token>`.
When mail arrives and no socket or hub was listening, the relay knocks on it — an empty
`POST` for UnifiedPush, a `content-available` background push for APNs — at most once per
30 seconds. The knock carries nothing. Targets expire after seven days unless renewed,
which the client does on every connect. APNs targets are refused with 501 unless the
operator has configured the `APNS_*` secrets.

### TURN

With `TURN_SECRET` and `TURN_URLS` configured, `/turn/<address>` issues two-hour coturn
`use-auth-secret` credentials to any client that can sign with a mailbox key. The username
is a hash prefix of the address, so a TURN log does not contain mailbox addresses. Without
the secrets it answers 501 and the client falls back to public STUN, saying so in Settings.
The coturn itself, and the ntfy server the wakes go through, are set up from `infra/`
at the repository root.

## Limits

| Limit | Value |
|---|---|
| Request body | 256 KB |
| Blob chunk | 96 KB |
| Blob chunks per address | 1,400 |
| Bytes per blob | ~90 MB encoded (64 MB of media) |
| Prekey bundle | 4 KB |
| Messages per mailbox | 500 |
| Bytes per mailbox | 8 MB |
| Hubs subscribed per mailbox | 16 |
| HTTP requests per object per minute | 120 (hub deliveries and publishes exempt) |
| Retention | 30 days |

## Tests

```bash
npm test          # node --test test/relay.test.mjs
npm run smoke     # live check of the deployed relay: hub, sync/ack, /post, TURN status
```

The worker runs in-process against a fake Durable Object runtime with real Ed25519
signatures: hub subscribe/publish/deliver, cross-relay posts, wakes, TURN, blob caps.
CI runs it on every push.

## Deploy

```bash
cd relay
npm install
npx wrangler login        # One-time: authenticate with Cloudflare
npx wrangler deploy
```

`wrangler.toml` configures the `relay.spheres.dev` custom domain, the `RELAY_ROOM` Durable
Object binding and `DO_JURISDICTION = "eu"`; you still need the DNS record in Cloudflare.
Secrets (`TURN_*`, `APNS_*`) are set with `npx wrangler secret put` and are optional.

**`compatibility_date` matters.** Ed25519 verification is load-bearing here — if
`crypto.subtle` cannot import an Ed25519 key, every authenticated request returns 401 and
the only symptom is clients reporting `Unauthorized`. It is pinned to 2025-01-01 for the
standard `Ed25519` algorithm name. Do not lower it.

**Deploy together with the client.** v3 clients need the hub; a v2 relay has none. Setting
`DO_JURISDICTION` renames every Durable Object, so mail queued before the change does not
carry across — fine for a pre-alpha, worth a maintenance window later.

**Orphaned v1 data persists.** v2 addressed Durable Objects by new names, so every object
v1 created is unreachable — but unreachable is not deleted, and v1 set no alarms, so that
storage remains. Purging it needs a `deleted_classes` migration, which Cloudflare refuses
while any binding references the class; see the note in `wrangler.toml`.

## Self-hosting

Nothing in the worker is specific to this deployment: it holds no keys, no configuration
and no user records. Point a client at your own instance from Settings → Relay Server
(`RelayConfig`). Your contacts do not have to move: your bundle tells them where you
listen, and they send there. Deploying your own copy is `wrangler deploy` from this
directory; a one-click "Deploy to Cloudflare" button is on the list once the repository is
public.

## Cost

Cloudflare Workers free tier covers 100,000 requests/day. Durable Objects and their alarms
bill separately and are not free on every plan — check current pricing before running this
for more than a handful of users. The hub keeps one object active per connected client,
which is cheaper than one per mailbox.
