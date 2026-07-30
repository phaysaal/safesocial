# Spheres — Rebuild Plan

**Date:** 2026-07-29
**Status:** Proposed
**Supersedes:** the aspirational parts of `architecture.md`, `protocol.md`, `CLAUDE.md`

---

## 1. Product goal

A social network with the functionality people expect from mainstream platforms — feed,
posts, stories, comments, reactions, chat, group chat, albums, voice/video calls — built so
that **there is no public audience anywhere in the system**. Every piece of content exists
inside a *sphere*: a named, member-scoped context with an explicit membership list and its
own encryption key. Content that is not addressed to a sphere does not exist.

Centralisation is minimised where it can be, and stated honestly where it cannot.

### Non-goals

- Global discovery, trending, public profiles, or follower counts. There is no "everyone".
- Anonymity from a determined state-level adversary. The goal is *no bulk surveillance and no
  platform-side data mining*, not resistance to targeted device compromise.
- Server-side content moderation. Spheres are private contexts; moderation is membership.

---

## 2. Where the project actually is

An honest baseline, established by reading the code rather than the docs. Details in
§11 and in `architecture_weaknesses.md`.

| Claim | Reality |
|---|---|
| Veilid P2P, no servers | Every byte flows through one Cloudflare Worker. No Veilid code runs. |
| XChaCha20-Poly1305 E2E encryption | Repeating-XOR, keyed by `SHA256(pubA‖pubB)` — derivable from public data alone. |
| Rust core with FFI bridge | Never compiled into the app. `RustCoreService.init()` binds a symbol that does not exist; no `.so` is bundled. All 2,352 lines are dead. |
| Encrypted backup / identity export | Writes the literal string `placeholder_vault_blob`. The secret key is not in the file. |
| Social recovery | UI only. Logs `"Reconstruction successful (simulation)"`. |
| Multi-device linking | The two devices join different relay rooms and send to channel keys that never exist. |
| Audience control (rings / close friends) | Four incompatible models; delivery ignores all of them and broadcasts to every contact. |

Roughly 1,000 lines of `lib/` are dead code, there are **zero Rust tests, one default Flutter
test, and no CI**.

**The most important structural fact:** the app is 100% Dart over a relay. That is a smaller,
healthier starting point than the docs suggest — there is one real system to fix, not two.

---

## 3. Transport decision: keep the relay

Veilid was investigated in depth before writing this plan. The conclusion is to **keep
relay-based messaging** and pursue decentralisation by a different route. This is not a
concession; the blockers are upstream gaps with no application-level workaround:

1. **No offline delivery.** Veilid has no store-and-forward. If the recipient is offline, there
   is nothing to deliver to. A social app needs asynchronous messaging as a baseline.
2. **No durable persistence.** Per the Veilid developer book, when a node holding a copy of a
   DHT record goes down, *that copy is lost to the network forever*. "Local rehydration" fires
   only from `open_dht_record` and only re-pushes copies the calling node already holds. Data
   survives only while its writer keeps coming back online.
3. **No media.** Veilid's BlockStore is unimplemented upstream (open issue #461). DHT records
   cap at ~1 MiB total / 32 KiB per subkey, so they are not a fallback. Photos and video are
   simply not possible.
4. **Mobile is a second-class citizen.** VeilidChat disables DHT hosting on mobile
   (`disable: ['DHTV']`) because phones drop off too often to be useful caches — mobile nodes
   consume capacity that desktop nodes must supply. A 10-second keepalive runs permanently,
   preventing the cellular radio from idling. iOS background execution and push are unsolved.
5. **The decentralisation win is smaller than it looks.** Cold start depends on two DigitalOcean
   droplets under one DNS zone with three hardcoded Foundation keys, and the default private
   route hop count is **1**, not 3. Trading Cloudflare for that is not obviously a gain.

There are also two traps worth recording so nobody rediscovers them: `set_dht_value` defaults to
`AllowOffline: true` and returns `Ok(None)` for a *queued* write, indistinguishable from success;
and SMPL schema subkey ranges are disjoint by design (`subkey < o_cnt` ⇒ owner-only), so the
shared-conversation-record model in `messaging.rs` cannot work — only the record creator can ever
write. VeilidChat uses one-writer-per-record outboxes for exactly this reason.

### The decentralisation path we take instead

Real decentralisation for this project means **removing the single trusted operator**, not
adopting a specific P2P stack:

- The relay becomes **dumb, blind, and interchangeable** — it sees rotating opaque mailbox IDs
  and padded ciphertext, never identities or a social graph (§6).
- The relay is **self-hostable** (a documented container image) and **user-selectable** in
  settings, with multi-relay support so different spheres can use different operators.
- Direct **peer-to-peer transport is opportunistic**: when two devices can reach each other, use
  it; otherwise fall back to a mailbox. Veilid may return here later as one such transport,
  scoped to text-only, foreground-only, best-effort — behind a feature flag, with the relay
  remaining the system of record.

This gets the property that matters — no operator can see who talks to whom — without depending
on an ecosystem that cannot yet deliver a message to a sleeping phone.

---

## 4. The core architectural idea: everything is a sphere

Today the codebase implements contacts, rings, groups, albums, and feed audience as five
parallel subsystems, each with its own membership notion, its own key derivation, its own relay
namespace, and its own bugs. That duplication is the single largest source of brokenness in the
app, and it is also what makes "no public audience" impossible to enforce.

**Collapse all of it into one primitive.**

```
Sphere
  id            random 256-bit, stable across membership changes, not derived from members
  name, icon    presentation only
  members       [{ identity_key, role, joined_at, invited_by }]
  epoch         monotonic; increments on every membership change
  sphere_key    random 256-bit symmetric key, one per epoch
  kind          dm | group | broadcast   (presentation hint only — not a security boundary)
```

Everything else becomes content addressed to a sphere:

| Today | Becomes |
|---|---|
| 1:1 conversation | a sphere with 2 members, rendered as chat |
| Group | a sphere with *n* members |
| Ring ("Inner Circle", "Family") | a sphere you post into |
| Close friends | a sphere |
| Album | a content type inside a sphere |
| `PostAudience.everyone` | **deleted** — there is no everyone |
| `ContentPrivacy.public` | **deleted** |
| `ContentPrivacy.onlyMe` | a sphere with one member (you) |
| Post / message / photo / call | items with a `sphere_id` |

The home feed is the union of items from every sphere you belong to, sorted by time. That looks
and feels like a normal social feed — but every item in it is member-scoped by construction, and
there is no code path that can produce an unscoped item. **The privacy property becomes
structural rather than a check somebody has to remember to write.**

Contacts remain, but shrink to their real job: the people you have exchanged keys with, so you
can invite them into spheres. A DM is just the sphere auto-created for a contact pair.

Consequences worth stating plainly:

- One membership model, one key-rotation path, one delivery path, one merge/conflict path — each
  implemented once and tested once.
- Removing someone from a sphere is a real security operation (epoch bump + re-key), not a local
  boolean.
- Content can be shared to multiple spheres by wrapping one content key per sphere, without
  re-encrypting the payload.

---

## 5. Cryptography

The design work is already done and does **not** need reinventing: `docs/privacy_protocol.md`
specifies X25519 ECDH, HKDF-SHA256, XChaCha20-Poly1305, per-content keys wrapped per recipient,
and epoch-based group key rotation. That document is sound. It has simply never been implemented.

Two amendments to it:

1. **Delete the `public` privacy level.** It contradicts the product goal.
2. **Add a separate X25519 identity subkey** rather than converting the Ed25519 key. Ed25519→X25519
   conversion is subtle and is currently a stub returning 32 zero bytes. Generate an X25519 keypair
   alongside the Ed25519 one, publish the public half in the profile, and sign it with the identity
   key. Ed25519 keeps its one job: signing.

### Implementation language: Dart, not Rust

`cryptography: ^2.9.0` is **already a dependency** in `pubspec.yaml` and entirely unused. It
provides X25519, XChaCha20-Poly1305, HKDF-SHA256, and Ed25519 with native acceleration. Using it
means real cryptography can land with **no FFI, no NDK toolchain, no `.so` bundling, and no
cross-compilation** — removing the exact obstacle that left the Rust core dead on arrival.

The Rust crate is therefore **not on the critical path**. Do not revive it as part of this plan.
Either delete it or leave it dormant and clearly marked as such; reconsider only if a non-Flutter
client is actually being built. (If it stays, drop the three unused heavyweight dependencies:
`prost`/`prost-build` with no `build.rs`, and `double-ratchet`.)

### Key hierarchy

```
Identity
  ed25519_identity      signs everything; never leaves the device
  x25519_identity       ECDH; public half published in the signed profile

Pairwise (per contact)
  shared     = X25519(my_x25519_secret, their_x25519_public)
  root       = HKDF(shared, salt=sorted(pubA‖pubB), info="spheres-pairwise-v1")
  send_chain = HKDF(root, info="spheres-send-v1")
  recv_chain = HKDF(root, info="spheres-recv-v1")

Sphere (per epoch)
  sphere_key = random_256()                      # fresh on every epoch
  distributed to each member wrapped under that member's pairwise key
  epoch increments on join, leave, and removal

Content (per item)
  content_key = random_256()
  payload     = XChaCha20-Poly1305(content_key, plaintext, aad = canonical item header)
  content_key wrapped under the sphere_key (and additionally under each recipient's
  pairwise key for DMs)
```

### Rules that must hold

- **Every inbound item is signature-verified before it is stored or displayed.** Authorship is
  never taken from a self-declared field. This closes the current forgery holes where any contact
  can inject posts, likes, reactions, or a spoofed `contact_accept` attributed to anyone.
- **AEAD associated data binds ciphertext to its header** (`sphere_id`, `epoch`, `author`,
  `sequence`, `timestamp`, `content_type`). This prevents an envelope from being relabelled or
  replayed into another sphere.
- **A message key is deleted after use.** Advancing a symmetric KDF chain per message gives
  forward secrecy: a device seized tomorrow cannot decrypt what it already read and discarded.
  (Full Double Ratchet — adding post-compromise security via a DH ratchet — is Phase 5. Say so
  in the UI rather than implying Signal-grade properties.)
- **Removal re-keys.** Removing a member bumps the epoch and generates a new sphere key that is
  never wrapped for them. They keep what they already have; they get nothing further.
- **No plaintext at rest.** See §7.
- **No silent crypto fallback.** If decryption or verification fails, the item is rejected and
  surfaced — never rendered, never "best effort".

---

## 6. Transport and delivery

Two separate problems: making the relay blind, and making delivery reliable. The second is what
the user experiences as "messaging is broken and unstable".

### 6.1 A blind relay

Today `room = base36(SHA256(salt‖sortedPair) & 0xFFFFFFFF)` — a 32-bit, permanently stable,
publicly precomputable identifier. The operator can therefore build the complete social graph,
and 32 bits is enumerable, which is how the current relay allows anyone to read or delete any
conversation.

Replace it with **derived rotating mailboxes**:

```
mailbox_seed = HKDF(pairwise_root or sphere_key, info="mailbox-v1" ‖ epoch ‖ period)
mailbox_keypair = Ed25519_from_seed(mailbox_seed)
mailbox_id = mailbox_keypair.public          # 256-bit, opaque, rotates each period
```

Every participant derives the same keypair independently. To read or write, a client signs a
server-issued challenge with the mailbox private key; **the relay verifies against `mailbox_id`
itself**, so it needs no stored membership list, learns no identity, and cannot be tricked by a
throwaway keypair. Because the ID rotates on a schedule, the operator cannot link periods
together into a conversation history.

Also required of relay v2:

- 256-bit IDs everywhere; no 32-bit folding anywhere in the system.
- Payload **padding to size buckets** so message length leaks less.
- Per-mailbox quotas, body-size caps, and rate limits — none exist today.
- **Truthful retention**: pick a number (30 days is reasonable), enforce it with a scheduled
  sweep rather than only on the write path, and publish it. Today the README says "5 minutes in
  memory" while the code writes 30 days to durable storage and never prunes idle mailboxes.
- **Remove the unauthenticated plaintext `/state` read.** Profiles (display name, bio) are
  currently world-readable by public key. Profiles move inside sphere-scoped encrypted delivery.
- Self-hostable container image + documented deployment, so the operator is a choice.

### 6.2 Reliable delivery — the actual stability fix

The current client has no delivery guarantees at all: no outbox, no acks, no sequence numbers, no
dedup, and a `sendViaRelay` whose boolean result is discarded, so a message composed while the
socket is down is rendered as sent and lost forever. On top of that there are **seven independent
`RelayService` instances** with independent sockets and reconnect timers, and `onDone`
unconditionally reconnects — including after an intentional disconnect, so sockets resurrect
themselves permanently.

The replacement:

- **One connection manager.** A single multiplexed relay connection, subscribing to many
  mailboxes. Explicit lifecycle: `connect` / `disconnect` / `dispose`, with intentional closes
  that do not trigger reconnect. Exponential backoff with jitter, and a real, observable
  connection state driving the UI (the status dot is currently hardcoded green).
- **A persistent outbox.** Every outgoing item is written to the local database *before* any
  network attempt, with state `pending → sent → acked`. Retries resume across app restarts. The
  UI shows real per-message state.
- **Sequence numbers and dedup.** Monotonic per-(sender, sphere) sequence, dedup by item ID on
  receive, ordering by sequence with a bounded reorder buffer. Gap detection triggers a targeted
  refetch — this is also what makes a real `refreshFeed` possible (today it is
  `await Future.delayed(seconds: 1); // Simulation`).
- **Acks and receipts as first-class state**, replacing the `delivered` flag that is never set.
- **Media as encrypted blobs, not file paths.** Chat and album items currently transmit local
  paths like `/data/user/0/…`, which are dead references on the recipient's device. Content-address
  blobs by BLAKE3, chunk and encrypt them, upload to a relay blob store with quotas, and reference
  by hash — one pipeline for chat, feed, and albums.

---

## 7. Local storage

`SharedPreferences` holding plaintext JSON is the wrong substrate: the feed silently truncates to
100 posts, deleted conversations leave their messages on disk forever, and everything sensitive is
readable by anything that can read the app sandbox.

Move to **SQLite (drift or sqflite) encrypted at rest with SQLCipher**, keyed from
`flutter_secure_storage`. This is what makes reliable delivery, local search, pagination, and
multi-device reconciliation implementable at all. Provide a versioned migration from the existing
`spheres_*` preference keys, and make deletion actually delete.

Also fix `resetEverything`, which currently recursively wipes the documents directory *including
the user's backups* — so "reset and restore" destroys the thing being restored from.

---

## 8. Phased plan

Each phase has an exit criterion. Nothing moves forward until it is met, and every phase leaves
the app in a shippable state.

### Phase 0 — Stop the harm ✅ *done 2026-07-29*

The app is publicly downloadable and makes safety claims it does not meet. Fix that before
building anything.

- Correct every false claim: the "XChaCha20-Poly1305" and "Network Privacy" rows in settings, the
  landing page's "no plaintext metadata" and "Your Device (P2P)" comparison, `CLAUDE.md`, and the
  aspirational sections of `architecture.md` / `protocol.md`. Label the build pre-alpha.
- **Disable the identity-destroying paths**: encrypted export, encrypted backup, restore, social
  recovery, and device linking all currently report success while doing nothing. Hide them behind
  a "not yet available" state rather than leaving loaded footguns in a shipped build.
- Make release signing **fail the build** when `key.properties` is absent, instead of silently
  falling back to the universally-known Android debug key. Rotate the keystore password off
  `spheres2026`.
- Set `allowBackup="false"` so identity material stops flowing to Google's cloud backup.
- Add **CI** (GitHub Actions: `flutter analyze`, `flutter test`, build) and the test scaffolding
  the repo has never had.
- Delete the ~1,000 lines of dead code (`privacy_selector`, `secure_media_viewer`, `dark_theme`,
  `content_privacy`, `friend_request`) and the unused Rust dependencies.

**Exit:** no user-visible claim is false; no code path can silently destroy an identity; CI is green.

**Outcome.** All of the above landed except one item that needs a human: **the release
keystore password is still `spheres2026`.** Rotating it (`keytool -storepasswd` /
`-keypasswd`, then updating `android/key.properties`) touches irreplaceable signing
material — if the keystore is lost or corrupted, every existing install has to be
uninstalled before it can be upgraded. Do it by hand, with a verified copy of the
keystore in a password manager first.

Verification at the time of completion: `flutter analyze --no-fatal-infos` and
`flutter test` both exit 0; zero analyzer errors and zero warnings (38 infos remain as
a tracked backlog); 12 tests pass.

### Phase 1 — Real cryptography *(1–2 weeks)*

- X25519 identity subkey, published in a signed profile.
- Implement `docs/privacy_protocol.md` in Dart on the `cryptography` package: HKDF, AEAD with AAD
  binding, per-content keys, key wrapping, symmetric ratchet chains.
- **Signature verification enforced on every inbound item.**
- Delete `crypto_service.dart`'s XOR path entirely — no compatibility fallback, no flag.
- Known-answer tests, round-trip tests, and negative tests proving tampered/forged/replayed items
  are rejected.

**Exit:** every wire payload is authenticated-encrypted under a key an observer cannot derive;
tampering and forgery are rejected by tests, not by inspection.

**Progress — foundation and direct messages done.**

Landed:

- `lib/crypto/spheres_crypto.dart` — X25519, HKDF-SHA256, XChaCha20-Poly1305, with
  domain-separated derivation. The only place in the app that touches a cipher.
- `lib/crypto/pairwise_session.dart` — symmetric KDF chains giving forward secrecy, with
  bounded skipped-key handling so out-of-order relay delivery still decrypts.
- `lib/crypto/envelope.dart` — versioned wire format, Ed25519-signed, header bound as AEAD
  associated data. Signature is verified before any decryption is attempted.
- `lib/crypto/session_manager.dart` — per-contact sessions, persistence, replay rejection.
- Identity gains an X25519 subkey (generated for existing identities on load, published in
  the signed profile). The Ed25519 key is untouched, so identities stay valid.
- `Contact` and the handshake carry the peer's X25519 key; the profile pull that always
  missed `displayName` (it read the wrong nesting level) is fixed and now also learns the
  exchange key.
- `ChatService` uses sealed envelopes. Authorship comes from the verified signature, and a
  payload whose `senderId` disagrees with the signature is dropped.
- `lib/app_wiring.dart` — identity wiring now runs after onboarding as well as at startup,
  so the first session works without an app restart.
- 34 tests pass, including forgery, tamper, replay, out-of-order, and cross-peer misuse.

**Phase 1 is complete.** Every wire payload is now authenticated-encrypted; the last
holdout (`call_service`) migrated with the calls work, and `crypto_service.dart` is gone.

Historical remainder, now done:

- ~~`call_service` signalling payloads~~ — sealed with `SealMode.wrap`.
- `group_service` still derives its key from the local user's own public key. A correct fix
  needs a per-sphere key, so this is best done together with Phase 3 rather than twice.
- `feed_service` and `album_service` send plaintext today; they need sealing (wrap mode) plus
  audience enforcement, which is also Phase 3 work.
- ~~`crypto_service.dart`~~ — deleted once calls migrated; nothing uses XOR any more.

### Phase 2 — Stable messaging *(2–3 weeks)*

Everything in §6. This is the phase that fixes the complaint that messaging is unreliable.

**Exit:** messages survive app kill, network loss, and out-of-order arrival; a scripted
two-device test exchanges N messages across forced disconnects with zero loss and zero
duplication; the relay cannot read a message or identify a participant.

**Progress — client reliability done; relay hardening still to do.**

Landed:

- `lib/services/outbox_service.dart` — a durable queue. Every message is written down
  before any network attempt and stays until the relay accepts it, with bounded retries,
  manual retry after giving up, and pruning of completed entries. It survives process
  death: an unsent message is still pending after a restart.
- Delivery receipts. The recipient returns a sealed `receipt` envelope, so
  `pending → sent → delivered` reflects the peer's device, not just the relay.
- `RelayService` connection lifecycle rewritten:
  - Intentional closes no longer reconnect. Blocking a contact or leaving a group used to
    resurrect the socket five seconds later, permanently.
  - Exponential backoff with jitter, replacing a fixed five-second retry.
  - The connect race is closed — the slot is claimed before the first `await`, so two
    rapid calls can no longer open two sockets and have the second discard the first's
    buffered messages.
  - A real `RelayConnectionState` is exposed and notified.
- The feed's network dot shows actual queue state instead of being hardcoded green with a
  "Relay network: connected" message that was true regardless.
- 45 tests pass, 11 of them covering the outbox state machine.

**Relay v2 landed** — the relay is now blind.

- Addresses are Ed25519 public keys derived from the pairwise secret
  (`lib/crypto/mailbox.dart`). The operator cannot compute one from public keys, so the
  social graph is no longer reconstructible from traffic. Distinct purposes (chat, feed,
  call) give distinct addresses, so channels between the same pair are unlinkable.
- Access is granted by signing the request with the address's private key, verified
  against the address itself. The worker keeps no membership list, and a throwaway keypair
  proves nothing — closing the hole where anyone could read or delete any conversation's
  mail.
- The unauthenticated `/state` endpoint is gone. It served display names and bios to
  anyone holding a public key. Only a signed prekey bundle (identity key + X25519 key) is
  public now, and the client verifies its signature, so the operator cannot substitute
  their own exchange key and sit in the middle.
- Handshakes move to `/inbox/<identity>`: open to write (a stranger has no shared secret),
  signed to read.
- Quotas and limits where there were none: 256 KB bodies, 500 messages and 8 MB per
  mailbox, 120 requests/minute, 4 KB prekeys.
- Retention is swept on a Durable Object alarm rather than only on write, so an idle
  mailbox actually expires.
- Payloads are padded to size buckets before transmission.
- Fixed while in there: `String.fromCharCode(...)` spread over a whole buffer, which threw
  `RangeError` on binary frames over ~100 KB inside the storage transaction, so the message
  was silently never queued. Also device pairing, where the two devices derived *different*
  rooms and sent to channel keys that were never registered — they now derive one shared
  address from the pairing secret.
- `compatibility_date` raised to 2025-01-01: Ed25519 verification is now load-bearing, and
  under the old pin a `crypto.subtle` failure would 401 every request with no other symptom.
- 65 tests pass, 10 covering mailbox derivation and request-signature binding.

**Deployment note:** the route names changed, so v1 and v2 do not interoperate. The worker
must be deployed together with the client build.

Remaining:

- **One multiplexed connection**: seven `RelayService` instances still exist, one per
  service.
- **Address rotation.** Addresses are secret-derived but stable, so an operator can still
  see that *some* pair has been talking for months. Rotating on a schedule needs a lookback
  window at least as long as the retention period, or mail queued to a retired address is
  lost — deferred rather than shipped half-working.
- **Sequence numbers and gap detection** for feed/group content; direct messages already
  get ordering from the ratchet index.
- **SQLite encrypted at rest** (§7), which the outbox and message history both want.

### Phase 3 — The sphere model *(3–4 weeks)*

- Sphere data model, encrypted store, and migration from contacts / groups / rings / albums.
- **Signed membership operations**: invite, accept, join, leave, remove — with epoch bump and
  re-key on every change, and an actual invite/join mechanism (there is none today; group IDs are
  local UUIDs no second device can derive).
- All content carries `sphere_id`; delivery is per-sphere; the receive path enforces membership.
- Feed becomes the union over spheres. `PostAudience`, `Ring`, `Contact.closeFriend`, and
  `ContentPrivacy` are deleted, not adapted.
- Fix the onboarding gap where identity wiring runs only at process start, so the first session
  after signup is not silently broken.

**Exit:** on two real devices — create a sphere, invite, accept, post, chat; a removed member
provably cannot decrypt anything published after removal.

**Progress — the model and its enforcement are in; the UI is not.**

Landed:

- `lib/models/sphere.dart` — the primitive: id (random 256-bit, not derived from the member
  set so it survives membership changes), name, kind, epoch, and members with roles.
- `lib/crypto/sphere_keyring.dart` — one symmetric key per epoch, retained for old epochs so
  history stays readable, with persistence.
- `Envelope` gains `SealMode.sphere` (wire version 2): content key wrapped under the sphere's
  epoch key, so the sender encrypts once regardless of member count. `sphereId` and `epoch`
  are covered by the signature and the AEAD associated data, so content cannot be relabelled
  into another sphere or another epoch.
- `lib/services/sphere_service.dart` — creation, add, remove, promote, leave; signed
  `MembershipOp`s; key distribution over the existing pairwise channels; content sealing and
  opening with a membership check on the author.
- **Removal is now cryptographic.** Every membership change bumps the epoch and mints a new
  key that is wrapped only for the remaining members. A removed member keeps what they
  already had and gets nothing further. This replaces a local `blocked` boolean.
- 83 tests pass. The 28 new ones cover the exit property directly: a removed member cannot
  open post-rotation content, remaining members keep reading across the rotation, and
  inbound operations are rejected when the author disagrees with the verified sender, when
  the author is not an admin, when the signature is forged, and when an older epoch is
  replayed. Content from a non-member is refused even when validly signed and encrypted
  with the right key.

**UI and migration landed.**

- **Invite acceptance closes the gap flagged above.** A create operation naming us now
  arrives as a `PendingInvite` and nothing is applied — not even the offered key — until
  the user accepts. Declining discards the key.
- Sphere list (with invitations), creation, and member management screens; routes at
  `/spheres`, `/spheres/create`, `/sphere/:id`.
- The composer now targets a sphere, and it is required: there is no "Everyone" option to
  fall back to. Stories pick a sphere too.
- `FeedService.createPost` takes a sphere and delivers to exactly its members. Previously
  it fanned out to every non-blocked contact regardless of the chosen audience.
- `Post.audience` is replaced by `Post.sphereId`. The post card names the sphere that
  actually received the post, instead of a "Close Friends" badge that meant nothing.
- **Deleted rather than adapted**, per the plan: `PostAudience`, `Ring`, `RingService`,
  `manage_rings_screen`, `Group`, `GroupService`, and all five group screens.
- One-time migration converts legacy groups and populated rings into spheres, skipping the
  two empty rings that were seeded into every install. It is deliberately local-only and
  broadcasts nothing, because that membership was never agreed with anyone.
- 91 tests pass.

**Feed content is now sealed.** Posts, likes and reactions are encrypted to the sphere's
epoch key before they leave the device, so the relay no longer sees post bodies or the
base64 photos inlined in them. On receipt the signature is verified, the author is checked
to be a member of the sphere, and the payload's `authorId`/`sphereId` must agree with the
signed envelope — `author_id` was previously a field the sender could set to anything.
Likes and reactions go only to the sphere the post belongs to, rather than to every contact.

**Phase 3 is complete.**

- The feed is the union over spheres: `posts` and stories are filtered to spheres we are
  still a member of, and to authors who are still members. Content whose sphere we left
  disappears from the feed instead of lingering because it happens to be in local storage.
  `postsIn(sphereId)` gives the per-sphere view.
- Direct messages are spheres of two, derived deterministically from the two identity keys
  (`SphereService.directSphereWith`). No invitation, no key distribution, and the two
  devices cannot disagree about what the sphere is. DMs deliberately keep the ratcheted
  pairwise transport rather than a shared sphere key — the ratchet gives forward secrecy
  that a sphere key cannot, so the sphere here is the membership and presentation model,
  not the transport.
- Albums belong to a sphere and their contributions are sealed to it. Album membership,
  which was a third parallel notion of "who can see this", is gone. Album items also now
  carry the image rather than a local filesystem path, which was a dead reference on
  anyone else's device — "shared" albums never actually shared anything.
- `Contact.closeFriend` and `toggleCloseFriend` deleted.
- 102 tests pass.

**Nothing in the app now sends plaintext, and there is no unauthenticated cipher left:
`crypto_service.dart` is deleted.**

Carried into later phases:

- Album item ingestion rides the feed channels. That works, but it is another sign the
  seven `RelayService` instances should become one multiplexed connection (Phase 2's
  remaining item).
- Group calls are still broken — invites cannot be accepted (Phase 4).
- Chat still has its own conversation store rather than reading through the DM sphere. The
  model is unified; the storage is not.

### Phase 4 — Feature parity inside spheres *(4–6 weeks)*

- Comments and reactions: persisted, broadcast, signed (comments currently vanish on restart and
  never reach anyone).
- Media pipeline end to end: chunked encrypted blobs, thumbnails, video compression — fixing chat
  media, album sharing, and the temp-directory paths that the OS purges.
- Stories with sphere-scoped expiry and view receipts.
- A real notification service, including push. Push is a privacy decision: prefer content-free
  wakeups that trigger a fetch, and document the metadata a push provider necessarily sees.
- Calls: fix the dead decline path (the caller rings forever), the un-acceptable group invites,
  and pre-accept ICE buffering. Replace the public `openrelay.metered.ca` TURN service; document
  honestly that TURN relaying exposes IPs to whoever runs it.
- Local search over the encrypted database — messages, posts, spheres, not just contact names.
- Fill in settings: block list management, storage/cache, relay selection, notification prefs.

**Exit:** a user can do everything they expect from a mainstream social app, entirely within
spheres, with no path that produces unscoped content.

**Phase 4 is complete except push notifications**, which is blocked on a product decision
rather than on work — see the note at the end of this phase.

**Progress — the data-loss and dead-feature bugs are fixed.**

- **Comments** are persisted and broadcast to the sphere, and verified against the
  signature on receipt. They previously updated an in-memory list and nothing else, so
  they vanished on restart and never reached anyone — including the post's author.
- **Chat media** carries the image instead of a local filesystem path. A photo sent to a
  contact used to arrive as a dead reference into the sender's own sandbox.
- **Likes and reactions** are stored under the real identity key. They were written
  locally as the literal string `'self'` while the wire carried the real key, so own
  reactions were not portable and self-detection broke for anything received.
- **Notifications** work. The screen filtered on `authorId == 'self'`, which `createPost`
  stopped writing once an identity existed, so it was permanently empty for every
  onboarded user. Actor names now resolve to contact names.
- **Group calls are reachable and acceptable.** Accepting an invite fell through a
  `pendingOffer` guard and did nothing; a group invite carries no SDP, so accepting now
  joins the call instead. The invite also carries the member list and the call type, which
  was ignored so video invites were joined as audio. A call entry point was added to the
  sphere screen — after the old group screens were retired the mesh code was unreachable.
- 102 tests pass.

Remaining in Phase 4:

- ~~**Media pipeline**~~ — done. Media is encrypted with a per-blob key, split into 48 KB
  chunks and stored out of band at `/blob/<address>/<index>`; the message carries only a
  reference plus a small inline thumbnail, so a list renders before anything is fetched.
  Each chunk is bound to its index and blob address as associated data, so chunks cannot
  be reordered or spliced between blobs. Addresses come from a fresh random seed rather
  than the content hash — content-addressing would let the operator see that two people
  hold the same image. **Video is uploaded untranscoded** (there is no codec in the
  dependency set) and capped at 24 MB, with no thumbnail, since extracting a frame needs a
  decoder we do not have. Adding one is a dependency decision, not a coding one.
- **Push notifications**: nothing exists, and this is the one remaining item that is
  genuinely blocked on a decision rather than on work. Every practical option puts a third
  party (FCM/APNs) in a position to see that *this device* received something and when,
  which is metadata the relay redesign was specifically built to avoid handing out. The
  options are: accept that with content-free wakeups, ship without push and rely on
  foreground sync, or take a dependency on a self-hosted UnifiedPush-style provider. That
  is a product call, so it is left explicitly unmade.
- ~~**Search**~~ — done. Covers messages, posts, comments, spheres and contacts, with
  snippets trimmed around the hit. Entirely local: there is no server that could answer a
  query without being told what you are looking for.
- ~~**Settings**~~ — mostly done: blocked-contact management, cached-media size and clear,
  and relay selection. The relay host is now user-configurable (`RelayConfig`), which is
  what makes the self-hosting story in `relay/README.md` real rather than theoretical.
  Notification preferences are still absent because notifications themselves are.
- ~~**Story view receipts**~~ — done, and deliberately narrower than the mainstream
  version: a receipt goes to the author alone rather than to the sphere, so members do not
  learn who else is watching, and it can be switched off in settings.
- ~~**Story replies**~~ — done. A reply is a private message to the author rather than a
  sphere-visible comment, so it rides the ratcheted direct path and gets forward secrecy
  that sphere-sealed content does not. It carries only the story's id: stories expire, and
  a reply should not resurrect content that was meant to disappear, so a reply to an
  expired story says exactly that.
- ~~**TURN**~~ — now configurable (`CallConfig`): custom STUN/TURN servers, or TURN off
  entirely so calls only connect over a direct path. The default is still the free public
  `openrelay.metered.ca`, which is stated plainly in the UI along with what a TURN server
  can see. Shipping a better *default* needs infrastructure to point at, which is an
  operational decision rather than a code one.

### Phase 5 — Decentralisation and recovery *(4–6 weeks)*

- Multi-relay support, user-configurable relay, published self-host image.
- **Multi-device — partially done, and deliberately so.** Device linking works: the primary
  shows a pairing code, the identity travels as a vault keyed by that code (so the relay
  carries only ciphertext it has no key for), and the secondary actually adopts it. That
  covers *moving* to a new device, which is what most people need.
  What is **not** done is running two devices at once. Both would share one identity and one
  set of ratchet chains, so they would advance the same chain independently and reuse
  message keys — messages arriving out of order or failing to decrypt. Doing it properly
  needs per-device keypairs with certificates signed by the identity key, sessions keyed by
  (contact, device) rather than contact, and fan-out to every device. That reaches into the
  working message path, so it was not attempted in a pass that cannot be tested on real
  devices. The limitation is stated in the linking dialog and in settings rather than left
  for a user to discover.
- Ratchet state is deliberately excluded from backups: restoring it onto a device that is
  still running would let two devices advance the same chain. Sessions re-derive; only
  ordering is lost.
- ~~Social recovery~~ — done. Shamir over GF(256) in Dart (`lib/crypto/shamir.dart`), with a
  threshold of 1 refused outright, duplicate and mismatched shards rejected instead of
  panicking, and — the load-bearing part — the reconstruction verified against the identity's
  public key before anything adopts it. Shamir has no integrity of its own, so too few shards
  or one bad one yields plausible nonsense, which the old path returned as success.
  Verification recomputes the public key from the seed rather than reading the copy stored in
  the second half of the private key: `ed.public()` only slices bytes 32..64, so trusting it
  validates half the secret and misses seed corruption entirely. A test caught that.
- ~~Encrypted backup~~ — done. `lib/crypto/vault.dart`: Argon2id at OWASP's mobile parameters
  plus XChaCha20-Poly1305, with the KDF parameters stored in the file and bound as associated
  data so they cannot be edited down to make brute-forcing cheaper. Backup, identity export
  and identity import are re-enabled. Backups still cover identity, contacts and posts only —
  extending them to spheres and messages is outstanding.
- *Optional, flagged:* opportunistic direct P2P transport; Veilid re-evaluated here.

**Exit:** no single relay operator is structural; a user can self-host; recovery restores a real
identity, verified.

### Phase 6 — Hardening *(ongoing)*

**Progress.**

- ~~Refresh `threat_model.md`~~ — done. Rewritten against what is actually built, adversary
  by adversary, with a ranked list of known gaps. The old one described the Veilid system
  that was never built.
- ~~Fuzz the wire parsers~~ — done. `test/crypto/parser_fuzz_test.dart` throws hostile and
  random input at every parser that sits behind the relay: envelopes, blob references,
  recovery shards, vaults, spheres, sessions and membership operations. Seeded, so a failure
  is reproducible. It found nothing, which is a weak signal but the right one to have.

Remaining, in the order that matters:

1. **Encrypt local storage.** Message history, sphere keys and ratchet state are plaintext
   JSON in SharedPreferences. This undermines several protections the rest of the system
   provides, and is the highest-value work left in the project.
2. **Run it on two real devices.** Nothing in seven phases has exchanged a message. Unknown
   unknowns dominate every other risk here.
3. **Independent security review**, which cannot sensibly happen before 1 and 2.
4. Reproducible builds and F-Droid distribution.

---

## 9. Engineering practices to adopt now

These are why the project keeps ending up half-finished, and they cost little to fix.

- **CI from Phase 0.** Nothing merges without `flutter analyze` + tests passing.
- **No stub may report success.** A function that cannot do its job throws or returns an explicit
  error. The recurring pattern here — `"status":"success"` from a placeholder, `SnackBar('Invitation
  sent!')` that sends nothing, `'Reconstruction successful (simulation)'` — is what turned
  incomplete work into *invisible* incomplete work.
- **Protocol version on every message**, with an explicit unknown-version path, so wire changes
  across phases are survivable.
- **Feature flags** for anything partially built, defaulting off in release.
- **Two-device integration tests in CI** against a local relay (Miniflare/workerd). Most bugs in
  this codebase are precisely the ones a single device cannot reveal: the group key derived from
  the sender's own public key, the sync rooms that never match, the media sent as local paths.
- **Docs describe what exists.** Aspirational design goes in a clearly-marked design doc.

---

## 10. Effort and sequencing

Roughly **4–6 months of focused part-time work** to reach the end of Phase 4, where the product
matches its description. Phases 0–2 are the highest-value stretch: they take the app from
"insecure and unreliable" to "genuinely private and dependable messaging", and they are the
prerequisite for everything else.

Recommended immediate order:

1. Phase 0 in full — it is measured in days and removes real user harm.
2. Phase 1, because Phase 2's mailbox derivation depends on having real pairwise secrets.
3. Phase 2, which resolves the stability complaint.
4. Then reassess scope before the larger Phase 3 refactor.

---

## 11. Reference: source-level findings

The specific defects behind the summaries above are recorded in the review that accompanied this
plan and in `architecture_weaknesses.md`. The load-bearing ones for sequencing:

- `crypto_service.dart:16-70` — XOR cipher, key derived from public data.
- `ratchet.rs:54-83` — `encrypt`/`decrypt` return plaintext; `ed25519_to_x25519` returns zeros.
- `ffi.rs:130-158` — vault create/unlock are placeholders returning success.
- `rust_core_service.dart:53-55` — binds a nonexistent symbol; the Rust core never initialises.
- `worker.js:82-114` — `/sync` and `/ack` verify a signature but not room membership.
- `feed_service.dart:128-134` — audience ignored; fan-out to every contact, unencrypted.
- `group_service.dart:167` vs `:207` — group key derived from the local user's own public key.
- `sync_service.dart:50,67,75,92` — device linking joins mismatched rooms and sends to
  nonexistent channels.
- `relay_service.dart:81-87` — `onDone` reconnects after intentional disconnects.
- `recovery.rs:16-33` — `threshold == 1` accepted; no threshold enforcement, no shard
  authentication, no verification of the reconstructed secret; panics on malformed shards.
- `build.gradle.kts:49-53` — release builds fall back to the Android debug signing key.
