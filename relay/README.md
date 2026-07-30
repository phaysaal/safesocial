# Spheres Relay (v2)

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

### What it can still see

Message sizes (bucketed by the client into 512B / 2K / 8K / 32K / 128K), timing, and that
some address is active. Removing those needs padding schedules and cover traffic, which are
not implemented. Cloudflare additionally sees IP addresses; the worker itself does not log
them.

### What changed from v1, and why

v1 addressed rooms as `base36(SHA256(salt + sortedPublicKeys) & 0xFFFFFFFF)` and
authenticated with *any* valid Ed25519 signature, never checking it against the room being
accessed. Two consequences:

- the operator could reconstruct the whole social graph by precomputing room ids from public
  keys, and the 32-bit space was small enough to enumerate;
- anyone could generate a throwaway keypair, sign a request, and read (`/sync`) or delete
  (`/ack`) any conversation's queued mail.

It also served display names and bios from an unauthenticated `/state` endpoint to anyone
holding a public key. All three are fixed here. v1 routes are removed rather than
deprecated, so an old client fails loudly instead of silently using the insecure path.

## Endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `WS /mbx/<address>?ts&sig` | signed by the mailbox key | Live delivery |
| `GET /mbx/<address>/sync` | signed by the mailbox key | Fetch queued mail |
| `POST /mbx/<address>/ack` | signed by the mailbox key | Delete fetched mail |
| `POST /inbox/<identity>` | **none, by design** | Send a contact handshake |
| `GET /inbox/<identity>/sync` | signed by the identity key | Read your handshakes |
| `POST /inbox/<identity>/ack` | signed by the identity key | Clear handshakes |
| `PUT /blob/<address>/<n>` | signed by the blob address | Upload a media chunk |
| `GET /blob/<address>/<n>` | none | Fetch a media chunk |
| `GET /prekey/<identity>` | none | Fetch a public key bundle |
| `POST /prekey/<identity>` | signed by the identity key | Publish your key bundle |

Blob reads are unauthenticated because the address is a 256-bit capability that only
travels inside sealed envelopes, and the bytes are encrypted before they arrive. Writes are
signed so a blob cannot be overwritten by a passer-by, and a chunk that already exists
returns 409 rather than being replaced. Blobs expire on the same 30-day clock as mail,
counted from last use.

The handshake inbox is deliberately asymmetric: a stranger has no shared secret to sign
with, so writes are open, but only the owner can read what arrived. The prekey bundle is
public because a new contact needs your X25519 key before any shared secret can exist — it
contains nothing but that key, your identity key, and a signature binding them together.

Signed requests carry `X-Spheres-Signature` (hex) and `X-Spheres-Timestamp` (ms) over
`METHOD + path + body + timestamp`, within a five-minute window. WebSocket upgrades pass
`sig` and `ts` as query parameters instead, over `WS + path + timestamp`, because the
WebSocket API cannot set request headers portably.

## Limits

| Limit | Value |
|---|---|
| Request body | 256 KB |
| Blob chunk | 96 KB |
| Blob chunks per address | 512 |
| Prekey bundle | 4 KB |
| Messages per mailbox | 500 |
| Bytes per mailbox | 8 MB |
| Requests per mailbox per minute | 120 |
| Retention | 30 days |

## Deploy

```bash
cd relay
npm install
npx wrangler login        # One-time: authenticate with Cloudflare
npx wrangler deploy
```

`wrangler.toml` already configures the `relay.spheres.dev` custom domain and the
`RELAY_ROOM` Durable Object binding; you still need the DNS record in Cloudflare.

**`compatibility_date` matters.** Ed25519 verification is load-bearing here — if
`crypto.subtle` cannot import an Ed25519 key, every authenticated request returns 401 and
the only symptom is clients reporting `Unauthorized`. It is pinned to 2025-01-01 for the
standard `Ed25519` algorithm name. Do not lower it.

**Deploy the worker before shipping a client build that expects v2**, and vice versa: the
route names changed, so the two versions do not interoperate. Any already-installed v1
client stops working the moment this deploys.

**The v2 migration deletes all v1 data.** v2 addresses Durable Objects by new names, so
objects created by v1 would become unreachable but not deleted — and v1 had no alarms, so
they would sit in storage indefinitely, contradicting the retention promise above. The
`v2` migration drops the old class, discarding that storage at deploy time. Anything still
queued for an offline v1 user is lost, which is the intended outcome: it cannot be
delivered to a client that no longer speaks the protocol.

## Self-hosting

Nothing in the worker is specific to this deployment: it holds no keys, no configuration and
no user records. Point a client at your own instance by changing the host in
`safesocial_app/lib/services/relay_service.dart`. Making that user-configurable, so
different spheres can use different operators, is Phase 5 of `docs/rebuild_plan.md`.

## Cost

Cloudflare Workers free tier covers 100,000 requests/day. Durable Objects and their alarms
bill separately and are not free on every plan — check current pricing before running this
for more than a handful of users.
