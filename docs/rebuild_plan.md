# Spheres — Rebuild Plan

**Date:** 2026-07-29, decisions added 2026-10-10
**Status:** Active. §12 records the decisions taken; §13 is the plan to finish.
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

**Phase 4 is complete except push notifications** (decided in §12.1, scheduled in §13) and
video transcoding (decided in §12.2, scheduled in §13).

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
  decoder we do not have. The dependency decision was taken on 2026-10-10 — see §12.2.
- **Push notifications**: nothing exists. This was blocked on a product decision, which
  was taken on 2026-10-10 — see §12.1. Work is scheduled as milestone M4 in §13.
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
  can see. Shipping a better *default* needs infrastructure to point at; that decision
  was taken on 2026-10-10 — see §12.3.

### Phase 5 — Decentralisation and recovery *(4–6 weeks)*

- ~~User-configurable relay~~ — done (`RelayConfig`, Settings → Relay Server).
  Multi-relay (different spheres on different operators) and a published one-click
  self-host deployment remain — milestone M8 in §13.
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

1. ~~**Encrypt local storage**~~ — done. `SecureStore` seals every sensitive value with
   XChaCha20-Poly1305 under a key in the platform keystore, binding each value to its own
   storage key, with a one-time migration for existing installs. SQLCipher would be the
   textbook answer and brings indexed queries too, but it is a native dependency and this
   work cannot be built or run on a device — a plugin that failed to link would break the
   app in a way no test here would catch. The interface is narrow enough that swapping the
   backing store later is a contained change.
2. **Run it on two real devices.** Nothing in seven phases has exchanged a message. Unknown
   unknowns dominate every other risk here.
3. **Independent security review**, which cannot sensibly happen before 1 and 2.
4. **Reproducible builds** — set up, not yet demonstrated. Toolchain pinned
   (`FLUTTER_TOOLCHAIN`, `.flutter-version`, Gradle pinned by hash), releases publish
   `SHA256SUMS.txt`, `scripts/verify_build.sh` lets anyone rebuild a release and diff it,
   and a CI job builds the same commit twice and fails if the bytes differ. Nobody has yet
   seen that check pass, and no release has been published with hashes, so it is
   "checkable" rather than "proven". A pinned container image and F-Droid metadata are the
   remaining steps — see `docs/reproducible_builds.md`.

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

The order originally recommended here (Phase 0, then 1, then 2, then reassess) was
followed, and Phases 0–3 are complete as of 2026-10. The remaining work is sequenced in §13.

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

---

## 12. Decisions taken on 2026-10-10

Three items in Phase 4 were waiting on a decision rather than on work. The decisions below
take the standard, well-trodden option in each case and record the costs honestly. The
operating preference behind all three: **infrastructure we run ourselves, in the EU**, and
third parties only where no self-run alternative exists.

### 12.1 Push notifications — content-free wakeups through a swappable provider

**What the problem is.** A phone cannot keep a WebSocket open in the background. Something
has to wake the app when mail arrives, and on both platforms that something is ultimately a
service run by Google (FCM) or Apple (APNs). Whoever runs it learns *that this device was
woken, and when*. The relay was redesigned specifically so that no party learns who is
talking to whom; push re-introduces one party that sees timing per device.

**Decision.**

1. **The app talks to one abstraction, `WakeService`,** which knows how to register a wake
   endpoint and to react to a wake by syncing. Everything else is a provider behind it.
2. **Android default: UnifiedPush**, pointed at a **project-run ntfy server in the EU**.
   No Google SDK in the default build, so reproducible builds and F-Droid are unaffected,
   and the server that sees wake timing is ours. Users who want Google's delivery can
   install the UnifiedPush FCM distributor; the app code path is identical.
3. **Android fallback inside the app: none that bypasses the abstraction.** If no
   distributor is present, the app says so plainly in Settings and relies on foreground
   sync. It does not silently degrade.
4. **iOS: APNs**, because there is no alternative. Background pushes carry no content and
   no alert text; the app wakes, syncs from the relay, and raises a local notification
   from decrypted content.
5. **The relay does the waking.** A client registers a wake endpoint on a mailbox's Durable
   Object (`POST /mbx/<addr>/wake`, signed by the mailbox key like every other request).
   On new mail the object `POST`s an empty body to that endpoint, coalescing wakes within a
   short window so a burst of messages is one wake. Registrations expire and are renewed
   on every connect, so a retired device stops being woken.
6. **One endpoint per mailbox on Android.** UnifiedPush hands out a distinct URL per
   registration, so the relay cannot tell that mailboxes A and B wake the same device. On
   iOS the APNs token is per device, so that linkage exists at the relay; it is recorded in
   `threat_model.md` rather than hidden.

*Amendment, 13 October 2026.* The ntfy connection shows a persistent notification on
Android, which the owner judged a poor first impression. Point 2 is kept and point 3
sharpened: the Android build now has two flavours. `foss` is as above. `play` embeds the
UnifiedPush FCM distributor (`org.unifiedpush.android:embedded-fcm-distributor`), which
sits *behind* `WakeService` as one more distributor, registers with Google Play services
the way a browser does (the relay's VAPID public key as the sender, so there is no
Firebase project, no Google SDK and no proprietary code in the APK), and is used only
when no external distributor is installed. Google then learns per-device wake timing,
the same thing Apple learns on iOS, and nothing else: the relay signs each knock (RFC
8292) and the body is the fixed word "wake" encrypted to the device (RFC 8291), sent
only because Google drops an empty push. The "not doing" line below still holds: there is
no FCM code path of its own, only a distributor behind the abstraction.

**Why this is the long-term stable choice.** The app depends on a published open standard
rather than a vendor SDK; the server component is one we operate and can move; FCM is
available to users who need it without a second code path; and the mechanism is the same
one Signal and Element use (content-free wake, then fetch), which has survived a decade of
OS background-execution changes. The honest cost is that on Android without FCM, some
manufacturers' battery managers kill background connections, so delivery on those phones
depends on the user allowing the distributor to run. Settings will detect and explain this.

### 12.2 Video — transcode on device with the platform codec

**Decision.** Use the platform's hardware encoder through the `video_compress` plugin
(MediaCodec on Android, AVFoundation on iOS) and play back with `video_player`.

- **Output:** H.264 + AAC in MP4, 720p, target 2 Mbps, with a poster frame extracted at
  transcode time and sent as the inline thumbnail. Container metadata (including GPS atoms)
  is dropped by the re-mux; a test fixture with location metadata must come out clean.
- **Limits:** 60 seconds for feed posts and stories, 3 minutes for chat and albums; a
  hard cap of 64 MB after transcoding, up from 24 MB. The relay's chunk index widens from
  three to four digits and enforces a per-blob byte cap of 64 MB.
- **Why not ffmpeg.** `ffmpeg-kit` was retired upstream in 2025; its forks ship 30 MB or
  more of native code per ABI, which inflates the APK and makes the reproducible build
  fragile. The platform encoder is already on every phone.
- **Cost.** A native plugin, pinned like everything else in `FLUTTER_TOOLCHAIN`. The
  reproducible-build CI job is the check that it stays pinned. Desktop targets get no
  transcoding and keep the current untranscoded upload with the lower cap.

### 12.3 Calls — run our own STUN and TURN in the EU

**What TURN is.** A voice or video call tries to connect the two phones directly. STUN is a
tiny service that tells a phone its own public address so it can offer it to the other
side. When both phones sit behind NATs that refuse inbound connections, which is common on
mobile networks, a direct path is impossible and the encrypted media is relayed through a
TURN server instead. The TURN operator cannot read the call (it is encrypted end to end
with DTLS-SRTP) but it does see both parties' IP addresses and how much data flowed. Today
the default TURN is `openrelay.metered.ca`, a free public service run by a company neither
we nor the user has any relationship with, and STUN is Google's.

**Decision.** Run a `coturn` server on a small VM in Germany (Hetzner, Falkenstein or
Nuremberg), serving both STUN and TURN, and make it the default in `CallConfig`. The relay
issues **short-lived TURN credentials** (HMAC time-limited, the standard TURN REST scheme)
to any authenticated mailbox address, so no credential is baked into the binary and the
server cannot be used as a free relay by strangers. Google STUN goes. "Custom" and "off"
remain available in Settings. Cost is a few euros a month plus bandwidth.

**Also, EU data location for the relay.** Cloudflare runs Workers wherever the user is,
but Durable Object storage can be pinned: construct ids via
`env.RELAY_ROOM.jurisdiction("eu").idFromName(...)`, so mailboxes, blobs and prekeys are
stored in the EU. One-line change, applied together with the TURN work.

**Longer term.** The relay itself stays on Cloudflare for now because the free tier and the
Durable Object alarms do exactly what a store-and-forward relay needs. A self-run relay on
EU hardware is the natural next step once the Worker's behaviour is stable and documented;
the client already takes an arbitrary host.

### 12.4 Smaller decisions recorded at the same time

- **Delete the dormant Rust.** `safesocial_core/` and `RustCoreService` are removed from
  the tree. Git history keeps them; nothing in the app references them except a dead
  provider and one unused `context.read`.
- **Concurrent multi-device is built properly, later.** Per-device keypairs with a
  certificate signed by the identity key, sessions keyed by (contact, device), fan-out to
  every device, and a device list with revocation. It touches the whole message path, so
  it comes after the first real-device test (M1), not before.
- **SQLCipher stays deferred** until there is a device to test a native plugin on.
  `SecureStore` is the interface it will slot behind.
- **Media viewer "Share" and "Download".** Share means re-sharing into a sphere through the
  composer; there is no other audience. Download saves to the system gallery after a
  confirmation that explains the file leaves the encrypted store.

### 12.5 Advertisements — decided 2026-10-14

Spheres may one day carry adverts, and the way it does was decided before the first
one so that it cannot drift towards the industry's: **like a television break, not like
a feed**. After twenty minutes of watching, one advert on Home, until the person closes
it; then the twenty minutes start again. What fills the slot is decided on the phone and
nowhere else.

- **No signal leaves the device.** The app never reads what the person does to choose an
  advert, and never reports what was shown, closed or opened. The phone fetches the
  whole catalogue, every category, with no identifier in the request, and picks locally.
  The host sees a fetch and nothing more; whoever serves the catalogue cannot tell a
  category on from one off.
- **The person chooses the categories**, from a fixed list of twenty-four in the app.
  On the free plan at least ten stay on; on a paid plan any number, down to none. No
  plan is sold yet, and the app says so rather than pretending.
- **Text only, marked sponsored, with a "why this?"** that is always true because the
  rule above is the only rule. A link opens outside the app and only when it is http(s).
- **Today there are none.** The framework (`AdService`, `AdCatalogue`, `AdChoice`,
  `AdvertCard`, Settings, Advertisements) is in place and tested; the operator's source is
  `NoAdverts`. Starting is one line in `AppServices`: a `JsonAdCatalogue` pointed at a
  version-1 document. Everything the person chose before that day applies on it. Until
  then the path is tried from a phone: Settings, Advertisements takes a catalogue address
  for that phone alone and can fill the slot without the wait;
  `https://spheres.dev/ads/test-catalogue.json` (from `landing/ads/`) carries three test
  adverts and two the app must drop.
- **Pricing, when it comes, is airtime.** The phone reports no impression, click or
  close, so there is nothing to bill per view; an advertiser buys a slot in a category for
  a period, as on television, and is told how many share it and nothing about reach. An
  advertiser portal (a Worker with D1 and Stripe, publishing the same JSON after the
  operator approves each advert by hand) is for the day there are advertisers; the app
  needs no change for it.

**Not doing:** any targeting beyond the chosen categories; frequency or conversion
reporting; an SDK from an advertising network; adverts in chats, spheres or stories.

### 12.6 Desires served, not exploited — decided 2026-10-25

People want to be seen, to know what others think of them, to miss nothing, to belong
and to stand a little above the group, to look without being looked at, to have a
private self, to be surprised. None of this is shameful. All of it is a lever, and the
large social apps and most attackers pull the same levers. Spheres will **serve these
desires and never exploit them**, and takes limited success over the alternative.

The difference is mechanics, not intent. Exploitation keeps the loop open so you come
back; service closes it so you leave satisfied. So the rule is about mechanics, and the
next feature is measured against it:

| Forbidden | Required instead |
|---|---|
| Rewards that arrive at variable, unpredictable times | Rewards that are certain, arriving when the person chose |
| Numbers shown to everyone | Numbers private to the person, shown on request |
| Anything timed to pull the person back | Anything timed to inform, at an hour they set |
| Loops with no end | An end state, said plainly |
| Pressure from what others can see about you | Nothing about you that you did not choose to show |
| Anything derived from behaviour without saying so | Nothing derived from behaviour, or every derivation named and switchable |

Served inside a sphere, the desires look like this, and this is the list to build from:

- **To be seen.** Appreciation that completes: reactions held and delivered once a day,
  at an hour the person picks, one line per post with every name (`AppreciationService`,
  Settings, Notifications, "Appreciation arrives"; "as it happens" remains a choice).
- **To know what people think of you.** A sphere can be asked, by one member, on an
  occasion, each answer a line delivered together. Consented, bounded, from people who
  know you. *Not yet built.*
- **To have done something, and have it known.** Achievements, announced in the form of
  their kind, answered by a book the sphere writes that closes, kept as chapters on the
  profile: `achievements_plan.md`. *Planned, not built.*
- **To miss nothing.** Certainty, not vigilance: the feed ends with "You're caught up"
  and a way out (`_CaughtUp` on Home, with "Done for now"). A digest at a set hour in
  place of the dots is the next step. *Dots remain for now.*
- **To belong and to matter.** Recognition given by people, never by a formula: admin
  badges exist; "member since", sphere anniversaries and a weekly prompt that becomes a
  ritual are to come.
- **To look without being seen.** Flash receipts are a switch; there is no "active now";
  this stays so on purpose.
- **A private self.** The Self sphere, vanish mode, protected media.
- **Curiosity and play.** Memories, polls, quizzes, a daily question: novelty from one's
  own people, which needs no algorithm.

The reactions' count row on a post card is shown to everyone today and is the one
standing breach of the second rule; it is to become private, shown on request.

**The second principle, 25 October 2026: the app carries words and never supplies them.**
What makes the large professional network feel metallic is separate from its hooks: the
machine speaks for people ("congratulate Sam on five years", one tap, "Congrats!" from
forty hands that typed nothing), occasions are detected from fields rather than declared
by anyone, everything is one template, and it answers instantly. Spheres keeps the warmth
and drops the metal, with balance, because people do forget and do struggle for words:

- **Reminding is good.** An occasion a person declared (a birthday they entered, an
  anniversary they announced, a moment they shared) may be brought to mind, at the hour
  the person set, as information. Never as a task, never with a count of the undone.
- **Helping to write is good.** The app may guide a message: show the occasion, ask
  questions that only this person can answer ("what did they do this year that you
  noticed?", "what do you wish for them?"), suggest a shape (a greeting, a memory, a
  wish), notice gently when nothing in the draft is particular to the person, offer to
  speak it instead of typing it. It never offers a sentence to send. There is no
  template to pick from and nothing goes with a single tap: sending needs words the
  person wrote or spoke.
- **Occasions are declared, not derived.** A date in a profile field that its owner
  entered is a declaration; a pattern in someone's activity is not. "Remind me about
  people I have gone quiet with" would be derived, so it exists only if named as such
  and switched on by the person, off by default.
- **A person's hand stays visible.** Colour, voice, a drawn line, uneven lengths, a
  silence where someone said nothing. Nothing is evened out, filled in or shown as
  missing.
- **Slowness and restraint.** A book that opens tomorrow; one quiet movement, once; no
  sound unless asked for.
- **Words.** "Moments" or "news" over "achievements", wherever the UI speaks.

Reactions stay as they are: a glyph is a gesture, not words the app put in a mouth.

**On the business worry.** Hooks buy early growth and sell it back as churn and distrust.
The moat is the one thing the large apps cannot copy without dismantling themselves:
people can trust this. Growth comes from the sphere itself, people inviting people they
know. Limited success is the honest expectation and may be wrong.

---

## 13. Plan to finish

Ordered by what unblocks the most. Each milestone has an exit criterion; a milestone is not
done until it is met. Sizes are focused part-time weeks.

> Feature parity with the Facebook app, item by item with a ten-milestone plan for the buildable remainder, is in `facebook_feature_list.md` (11 Oct 2026); it starts after the items below.

| # | Milestone | Size | Exit criterion |
|---|---|---|---|
| M1 | **Ground truth on hardware** | 1 | Two physical Android phones on different networks exchange direct and sphere messages, share a photo, complete a call, link a device, back up and restore. *First session 11 Oct 2026 (same Wi-Fi): messages, media, offline delivery, spheres and posts passed; the call crashed the receiver (fixed), unacknowledged publishes lost messages (fixed), notifications were never requested (fixed), own mail echoed from the shared mailbox churned the socket (fixed), a restart replayed an old call offer (fixed), unread counts forgot what was read in an open chat (fixed). Later the same day: video call, voice call with one phone on mobile data (direct ICE path, no TURN yet), view-once, disappearing timer, voice note (was sent as a local path, fixed), device linking (request was published before the mailbox was confirmed, fixed; the code field was autocorrected, fixed) and a post reaching the linked device all passed. A ntfy wake (public ntfy.sh) brought the stopped app back with a notification in four seconds, three times in a row; an encrypted backup restored from Settings on the tablet (the dialog had never asked for the passphrase, fixed). A call forced through TURN (relay-only ICE policy) connected phone to tablet and the server carried 15 KB/s each way; while setting it up, a mailbox refused the tablet because sixteen dead hub ids from the day's restarts filled it (fixed: stable hub id per install, relay evicts the oldest). Nothing in M1 is left to run.* A checklist in `docs/device_test.md` passes end to end. Fix what breaks before anything below. |
| M2 | **Housekeeping** | 1 | Rust crate and `RustCoreService` deleted. Media viewer Share and Download implemented. One multiplexed `RelayService` replaces the six. `architecture_weaknesses.md` and `analysis_review.md` marked historical in their headers. |
| M3 | **EU infrastructure** | 1 | `coturn` running in the EU (as of 11 Oct 2026: on the Scaleway Stardust instance in Amsterdam that also hosts ntfy, as `turn.spheres.dev` with TLS on 5349 from a certificate Caddy renews); relay issues short-lived TURN credentials; `CallConfig` default points at it and `openrelay` is gone; Durable Objects pinned to the EU jurisdiction; an `infra/` directory holds the server setup as code *(added 11 Oct 2026: templates, an idempotent `setup.sh` and an external `check.sh`)*. Exit: a call between two phones on different cellular networks connects through our TURN. |
| M4 | **Push notifications** (§12.1) | 2 | `WakeService` abstraction, UnifiedPush client, `/mbx/<addr>/wake` registration and coalesced wake on the relay, project ntfy server in the EU, APNs for iOS, notification preferences in Settings. Exit: with the app killed, a message produces a notification on Android via UnifiedPush and on iOS via APNs, and the relay log shows no content. *Android half met on 11 Oct 2026: ntfy 1.25.2 on the phone, first against the public ntfy.sh, then against the project's own server at `ntfy.spheres.dev`, which woke the stopped app in two seconds; iOS remains.* |
| M5 | **Video** (§12.2) | 1–2 | Transcode on pick, poster thumbnail, caps enforced in UI, relay chunk index and byte cap widened, playback in chat, feed, stories and albums. Exit: a 3-minute 4K phone recording sends as a 720p clip under 64 MB with no location metadata and plays on the other phone. |
| M6 | **Backups cover everything** | 1 | Vault includes spheres, keyring, sphere chats, messages, albums and saved items; ratchet state stays excluded by design. Exit: restore onto a wiped phone reproduces every screen's content. |
| M7 | **Concurrent multi-device** (§12.4) | 3–4 | Device certificates, per-device sessions, fan-out, device list with revocation; linking adds a device instead of moving the identity. Exit: two phones with one identity both send and receive in a direct chat and a sphere without decryption failures, and revoking one stops its delivery. |
| M8 | **Self-hosting and multi-relay** | 1 | A one-click relay deployment (template repository plus "Deploy to Cloudflare"); a sphere can name its relay and members honour it. Exit: a sphere hosted on a second relay works end to end. |
| M9 | **Hardening, continued** | ongoing | A release published with `SHA256SUMS.txt` and reproduced by `verify_build.sh` on a second machine; pinned build container; F-Droid metadata; address rotation and sequence numbers for sphere content (Phase 2 remainders); then an independent security review. |

**Status, 2026-10-11.** The code side of M2–M8 landed in one pass, ahead of M1, at the
owner's request to have everything in place before the two-phone test: hub transport with
relay tests, Rust removed, media viewer share/save, video transcoding, full backups,
notifications with UnifiedPush/APNs wake, relay-issued TURN, EU jurisdiction, federation
(each contact reached on their own relay), and multi-device with per-device sessions,
signed device lists, link and revoke. 534 app tests and 14 relay tests pass; a debug APK
builds. What M3 and M4 still need is *infrastructure*: a coturn, an ntfy server and the
APNs key, each a `wrangler secret`. M1 is now the gating item: every one of these changes
touches the message path and none has been seen on hardware.

Roughly **three to four months** was the original estimate at the pace of the earlier
phases; the remaining work is M1, the operator infrastructure, and M9.

**Occasions, 25 October 2026.** The celebration of events inside a sphere, from an award
read aloud to a birthday table laid by people, is planned in `achievements_plan.md` as
six milestones C1 to C6 with exit criteria; C1 (the occasion post, the page item, the
clock and the chapter) is the first to build.

**Teenagers, 25 October 2026.** The crew sphere, a guardian who approves contacts and
sees nothing else, and fifteen features that end rather than hook (pass the camera, the
story we wrote, the capsule, study hall, pass a note, sleep on it, our words, the quote
board, the mask, who knows me, the scrapbook, I'm not okay, lights out, not now, the
eighteenth) are planned in `teen_plan.md` as milestones T1 to T5; T1 (age, guardian,
crew) comes first because everything about minors depends on knowing who is one.

**The look, 25 October 2026.** Colour and light as numbers in the payload, applied by
every viewer at draw time to the original pixels, changed after posting through the
existing edit path with no new upload, the original one toggle away; a true-skin
correction computed from the picture; nothing that changes a face. Planned in
`look_plan.md` as L1 to L3.

**Not doing**, so that nobody re-opens it by accident: Veilid or any DHT transport (§3);
a public audience of any kind (§1); server-side moderation; an in-app FCM code path that
bypasses the wake abstraction; ffmpeg in the app.

## Session recovery

Pairwise chains advance in lockstep and nothing repaired them if the two sides
ever disagreed. Every later message failed to authenticate, the conversation
was over, and the only symptom was that messages quietly stopped arriving.
Found on two devices; the cause that time was a race in `KdfChain.next()`, but
a crash between sealing and persisting, or restoring a backup on one side, does
the same thing.

Chains can now be restarted. `PairwiseSession.resetEpoch` is folded into the
chain seeds, so a restart derives genuinely new chains rather than replaying
the old ones — an old ciphertext must not become valid again. Both sides can
re-derive because the root comes from a static X25519 agreement, which is the
one piece of state a divergence cannot damage. The announcement is sealed with
`SealMode.wrap`, since a request to fix the chain cannot travel on it.

Detection is three consecutive authentication failures from one peer, with a
five-minute floor between restarts. Three rather than one, because a single
failure can be a corrupted delivery; a floor, because a restart discards
in-flight messages and a recurring fault must not become a loop that destroys
everything after it. The trigger is trustworthy because the envelope signature
covers the ciphertext as well as the header — an authentication failure that
passes the signature check can only have come from the real peer.

Queued messages are marked failed rather than dropped. The outbox holds only
sealed bytes, by design, so they cannot be re-sealed under the new chain; they
would retry forever and never arrive.

**Known limits.** Only the receiving side detects a fault, so someone whose
messages are vanishing into silence has to act — hence the manual
"Re-establish secure session" in the chat menu. Detection watches the chat
channel only; feed and sphere traffic use wrapped or sphere keys and do not
ratchet, so they cannot diverge this way.

## Delivery guarantees

Content sent while the other side was away used to be lost, and three separate
faults could each cause it. Recorded here because the fix changed an
architectural assumption.

**The relay always queues now.** It used to queue only when it believed nobody
was listening, which it could not judge: a mailbox is shared by both parties,
so a stale socket belonging to the *sender* — hibernatable sockets outlive an
app that was killed — looked exactly like the recipient being present. Live
delivery over the WebSocket is now a latency optimisation and the mailbox is
the guarantee. The cost is that a message delivered live still sits in the
mailbox until the recipient's next sync acknowledges it, so it is fetched once
more and discarded; every receive path already discards by message id.

**Everything outbound goes through a durable queue.** Direct messages always
did. Feed posts and, later, group messages did not: the send result was
discarded, and it fails whenever there is no live socket, so the content simply
vanished with nothing said. There are two queues rather than one because a
queued entry is bound to the channel that can deliver it — direct messages
travel the pairwise chat channel, sphere content travels the feed channel.

**The fallback relay host has to exist.** It did not: the hostname named an
account subdomain that was never registered, and `workers_dev` was off. The
client also passed the fallback flag into its own retry, so one failed
connection pinned a channel to the dead host permanently. Retries now return to
the primary, and the attempt counter survives the reconnection that replaces
the connection object — without that the backoff reset to zero every time.

## Converging membership

Two admins can change a sphere at the same moment, neither having seen the
other, and both operations then claim the same epoch. The rule used to be

```dart
if (op.epoch <= existing.epoch) return;   // "already applied, or a replay"
```

so the second to arrive was discarded. Devices that saw the two in different
orders ended up with different member lists, permanently, with nothing to
detect it. Every governance decision rests on that list, so it had to converge
before anything else was built on top.

Operations now have a deterministic name — the hash of the bytes their author
signed, so it cannot be chosen or lied about — and a total order: earlier
timestamp wins, ties broken by that hash. Both devices compare the same two
operations and reach the same answer.

Two details make it work:

* A sibling is validated against **the state its author was looking at**, kept
  alongside the operation that produced the current epoch. Judging it against
  our own already-moved state would reject the winner for describing a
  membership that no longer matches.
* The winner's key replaces the one stored for that epoch, so everyone
  encrypts to the same thing. Content sealed in the gap — usually seconds — is
  unreadable to others. That is the unavoidable cost of two people having
  changed the same epoch, and it is bounded by how long the second operation
  takes to arrive.

A superseded change of our own is re-issued once at the next epoch, guarded so
it cannot loop and skipped when the winner already achieved the same thing.
Transfers and leaves are not retried: both are decisions about a state that has
since changed. Every supersession is written to the audit log, because an admin
action that quietly evaporates is exactly what members cannot be asked to
trust.

Ordering by wall clock means a device with a slow clock tends to win. That
decides which of two honest changes lands first and nothing else — authority is
still checked separately, and winning a tie confers none — so it is not worth a
distributed clock to fix.

## Reaching a peer

A member could only reach whoever invited them. Everyone else in a sphere was a
name with no way to derive a shared secret, so content could only ever flow
from its author: if the author was away and the relay had already dropped its
copy, there was nobody else to ask. That is the prerequisite for any
peer-assisted sync, and it was missing.

Member lists now carry each member's X25519 key, signed along with the rest of
the operation.

**These keys address transport and nothing else, and are never promoted into
the address book.** The author of a membership operation asserts them, so a
dishonest author could name its own key in place of somebody else's. That
cannot expose content: sphere content is sealed with the sphere key, so a
misdirected envelope is unreadable to anyone outside the sphere and reveals
nothing to anyone already in it. The damage is a member who cannot be reached,
which is a nuisance rather than a breach. Adopting the same key as a contact's
would be a different matter — direct messages are protected by exactly this
key — so `memberExchangeKey` prefers the address book when it has an entry and
falls back to the member list only when it does not.

## Asking a peer for what you missed

The relay covers being offline for a few hours. It does not cover being away
longer than its retention, a mailbox trimmed because it filled, joining a
sphere and wanting what came before, or any future bug that drops something. In
every one of those the content still exists — on the phones of everyone else in
the sphere — and there was no way to ask for it.

A member now keeps the sealed envelopes it receives, tells two peers per round
which ones it holds, and gets back what it is missing.

**Envelopes are archived exactly as they arrived.** A relaying member cannot
sign as their author, so the original signature has to travel with the content.
That is also what makes the whole thing safe without any new trust: the
receiving side runs the same checks as always — author's signature over header
and ciphertext, author confirmed to be a member, sphere key required — so a
dishonest peer can withhold but cannot forge, alter or invent.

Content is named by **envelope id** rather than by what is inside it, so posts,
likes, comments, group messages and album items are all covered by one
mechanism that never has to interpret any of them.

Bounded in three places, because none of this is worth a flood: 300 ids in a
digest, 20 items or 128 KB in a reply, two peers per round. Anything that does
not fit converges on a later round. The relay refuses bodies over 256 KB.

Deleting stays personal and permanent: `_mergePost` now refuses content whose
id is in the local tombstone set, so a post someone removed does not reappear
the next time a peer offers it back.

Retention is a user setting, and has an honest consequence worth surfacing in
the UI — **a sphere remembers for as long as its most patient member does.** If
one person keeps everything they become the sphere's archive; if everyone keeps
a week, the sphere genuinely forgets.

Still to do: buffer likes and comments that arrive before the post they refer
to, which are currently dropped, and which gossip makes far more common.

## A socket that stops delivering

A WebSocket can go quiet without ever closing — a NAT drops an idle mapping,
the network hands over, the relay lets it go. `onDone` never fires, so the
reconnect logic never runs, and the app sits there believing it is connected
while its mailbox fills up. Seen on two devices: a peer's reply reached the
relay, the recipient's app was running and idle, and nothing arrived until it
was restarted.

Connections now record when they last saw traffic, and a quiet one is checked
rather than trusted. The check is deliberately **evidence-based**: fetch the
mailbox over HTTP, which does not involve the socket at all. Anything found
there is something the socket failed to deliver, which is proof rather than
suspicion, and the connection is replaced. Nothing is lost either way, because
the fetch delivers what it finds.

Checked every two minutes per client, and on every app resume — returning to
the foreground is when a socket is most likely to have died unnoticed, since
the phone slept or the network changed while nobody was watching.

This pairs with the earlier retry fixes: the backoff now grows properly, so a
connection that genuinely cannot be made backs off instead of hammering, while
one that is merely stale is noticed within a couple of minutes.

## One way out

Everything addressed to a sphere now leaves by a single path: `queueForMember`
on FeedService. Posts, group messages and album items all take it.

That matters for more than tidiness. Each service that grew its own send path
also grew its own version of the same bug. Album items were the worst: they
went out on a relay client of their own, addressed by member, while that client
only ever held a connection keyed by album — so the lookup found nothing and
every send was discarded. Sharing an album item did nothing whatsoever, in
either direction, and nothing said so. That client also derived its mailbox
from a *local* secret no other device could compute, so it could not have
worked even had the addressing matched. It is gone.

Archiving moved into that same path. It used to happen only when publishing a
post, which meant our own group messages and album items were never archived —
so a peer asking us for what they had missed could be given other people's
content but never our own.

The rule to keep: if something is addressed to a sphere and does not go through
`queueForMember`, it is neither durable nor recoverable, and it will fail
quietly.
