# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Spheres is an in-development social network in which no content has a public audience.
Everything is scoped to a *sphere*: a named group with an explicit membership list and its
own encryption key. Identity is an Ed25519 keypair plus an X25519 exchange key. Part of
the SafeSelf umbrella project (Phase 2, after SeeSelf).

**Read `docs/rebuild_plan.md` before making architectural changes.** It is the
authoritative plan, records every decision taken (transport, cryptography, push, video,
TURN), and lists what remains. §12 holds the decisions; §13 is the plan to finish.

## Ground truth about the current build (v0.8.0+, 2026-10)

- **The app is 100% Dart over a Cloudflare Worker relay.** No Veilid, no DHT, no
  peer-to-peer. The Rust crate and `RustCoreService` were deleted; git history has them.
- **Cryptography is real and lives in `lib/crypto/`.** X25519 + HKDF + XChaCha20-Poly1305
  via `cryptography`, Ed25519 via `ed25519_edwards`. Envelopes are version 3 and carry the
  sender's device key. Sessions are per *device pair* (`session_manager.dart`); a person's
  devices are certified by their identity key (`device.dart`) and published in the signed
  prekey bundle. Sealing to a person means one envelope per device, plus copies to our
  own other devices.
- **Transport is one hub socket per client** (`RelayHub` in `relay_service.dart`), with
  mailboxes subscribed over it by signature. Services keep their own `RelayService`
  facades; all share the hub. A contact on another relay is reached by a signed HTTP post
  to that relay (federation); the host comes from their bundle.
- **Local storage is encrypted at rest** (`SecureStore`); new sensitive keys must be added
  to its list. Backups (`backup_service.dart`) cover every store except sessions and
  outboxes, and double as the device-link payload.
- **Media:** images re-encoded on pick (engine codec, downscaled, no metadata); video
  transcoded on-device (`video_transcoder.dart`, platform encoder, no ffmpeg) with posters;
  everything chunked and encrypted (`blob_service.dart`). `MediaThumb` renders every
  reference kind.
- **Media origin score.** Before an image is re-encoded, `ProvenanceScanner` reads what the
  file says about itself (camera EXIF, editing software, date disagreement, XMP and Content
  Credentials marks, PNG generator chunks, file name, dimensions) and produces a
  `MediaProvenance`: a 0–10 score plus signal *codes*. It is written as a `.prov` sidecar
  beside the local file and travels in `Post.provenance` / `Message.provenance`, one entry
  per media ref. Only codes and a sanitised tool name cross the wire; the receiving device
  renders the sentence and always shows the disclaimer. The in-app camera button yields
  10; a maker's own AI mark yields 0. It never looks at pixels and is not a detector.
  Per-chat and per-sphere "blur media until tapped" lives in `LibraryService`.
- **Notifications** are built on-device from decrypted content (`notification_service.dart`);
  wakes are content-free through `wake_service.dart` (UnifiedPush on Android, APNs via the
  iOS runner). `main()` has a `--unifiedpush-bg` entry that runs `BackgroundSync` with no UI.
- **Calls** get STUN/TURN from the relay (`CallConfig.resolve`); without an operator TURN
  they fall back to public STUN and say so.
- **Key verification** (`crypto/safety_number.dart`) covers both identity keys and every
  device key; a contact's verified number is stored and a changed key shows a banner.
- **Local organisation** lives in `LibraryService`: saves, stars, pins, mutes, archives,
  locked chats, blurred media, hidden words, member notes, stickers. Everything in it stays
  on the device.
- **Message kinds.** `Message.kind` is text, poll, location, contact, video_note, sticker,
  call or system, with structured content in `payload`; `Post.kind` is post, event or poll.
  Control traffic between devices and contacts rides small sealed envelopes: `chat_edit`,
  `chat_delete`, `chat_pin`, `chat_settings`, `read`, `poll_vote`, `location_update`,
  `profile`, `devices`, `contacts`; sphere-side equivalents are `sphere_msg_*` items and the
  feed carries `post_edit`, `post_pin`, `event_rsvp`, `post_vote`, `coauthor_accept`,
  `report`. Every one is attributed to the signed sender and, where it matters, checked
  against sphere roles on receipt. Add a new kind by extending the model, the sender, the
  switch in the receiver, and `describeMessage` for notifications.
- **Invite links** are `spheres://join?s=&t=&via=&n=`; the request goes to the admin's open
  inbox and approval makes the requester a contact and a member in one step.
- **Not built, by decision:** an SFU for large group calls (mesh only), any pixel-level
  classifier (nudity or AI-image detection; the origin score reads metadata only),
  communities as spheres of spheres, pending-post approval queues, story drawing.
- **Still open:** the first two-physical-device test, an operator-run coturn/ntfy/APNs,
  reproducible-build proof, external audit. See the plan's §13.
- Directory names: the app is `safesocial_app/`, the Dart package `spheres_app`, the
  product Spheres.

### House rule

**A stub must never report success.** Code that cannot do its job throws or returns an
explicit error. Silent placeholders are what turned incomplete work in this repo into
invisible incomplete work. If a feature is not finished, the UI says so.

### Second rule

**Nothing here has been run on two real devices.** When a change touches the message
path, say so in the commit and prefer changes that a test can cover. Emulator pairs cannot
scan QR codes; debug builds print the invite link instead (see `identity_service.dart`).

## Build & run

### Flutter app (`safesocial_app/`)
```bash
flutter pub get
flutter analyze --no-fatal-infos   # errors and warnings must stay at zero
flutter test                       # 590 tests in 46 files under test/{crypto,models,services}
flutter test test/some_test.dart
flutter run
flutter build apk --debug
flutter build apk                  # release — needs android/key.properties, refuses debug key
```
The toolchain is pinned in `FLUTTER_TOOLCHAIN` (Flutter 3.41.5, Dart 3.11.3, Gradle 8.14,
AGP 8.11.1, Kotlin 2.2.20, Java 17). Bump it in a commit of its own.
`PUB_CACHE` on this machine points at `/mnt/ssd/pub-cache`; if that volume is not
mounted, `pub get` fails with a permission error rather than a missing-path error.

### Release
```bash
./build_release.sh                 # bumps app_info.dart + pubspec, builds, writes SHA256SUMS.txt
scripts/verify_build.sh            # rebuilds a release and diffs the bytes
```

### Relay (`relay/`)
```bash
npm test                           # node --test, in-process fake Durable Objects, real Ed25519
npx wrangler dev
npx wrangler deploy                # deploy together with the client; v3 clients need the hub
```

### CI (`.github/workflows/ci.yml`)
Analyze, test, debug APK; a second job builds the same commit twice and fails if the bytes
differ; a third runs the relay tests.

## Architecture (as built)

```
Flutter UI (Provider/ChangeNotifier + GoRouter)
    ↓
AppServices (lib/app_services.dart) builds and loads every service, in order;
app_wiring.dart connects the identity to all of them (startup, onboarding, link)
    ↓
Dart services (lib/services/) — one ChangeNotifier per concern
    Identity (devices) · Contact (device lists, bundles) · Chat · SphereChat · Feed · Album
    Sphere · SphereSync · Sync (device link) · Call · Media · Blob · Outbox (per device)
    Search · Backup · Library · Notification · Wake · SecureStore
    ↓
Crypto (lib/crypto/) — device certs, per-device-pair sessions, envelopes v3, keyring,
    mailbox derivation, blobs, vault, Shamir
    ↓ one WebSocket to /hub, signed HTTP for everything else
relay/worker.js — Cloudflare Worker + Durable Objects, EU jurisdiction
    /hub/<id>        one socket per client; sub/pub/msg frames
    /mbx/<addr>      mailbox: sync/ack, subscribe/publish, post (federation), wake
    /inbox /blob /prekey /turn
```

- Six services still hold their own `RelayService` facade; that is fine now, they share one
  socket through `RelayHub`.
- The relay cannot identify participants: an address is derived from a secret only the
  participants share. It sees timing, size buckets, and which addresses one client holds.

## Storage model

| Store | Contents |
|---|---|
| `flutter_secure_storage` | `spheres_identity_secret`, the `SecureStore` wrapping key |
| `SharedPreferences` via `SecureStore` (sealed) | sessions, keyring, spheres, sphere chats, messages, contacts, posts, outboxes, albums, archive, invites, audit log, votes |
| `SharedPreferences` plaintext | `theme_mode`, relay host, call config — nothing secret |
| App documents dir | `backups/*.spheres`, decoded media, voice notes |

New sensitive keys must be added to `SecureStore`'s sensitive-key list or they are written
in plaintext.

## Conventions

- **State:** Provider with `ChangeNotifier`; services injected at the root.
- **Navigation:** GoRouter with named routes.
- **Wire format:** every payload is an `Envelope` (signed, sealed) whose plaintext is JSON
  with a `type` field. New message kinds get a parser test and an entry in
  `test/crypto/parser_fuzz_test.dart`.
- **Tests:** a bug fix on the message path comes with a test that fails before the fix.
  Several past fixes were found by two-emulator live tests; record those in the commit.
- **Commit messages** describe the user-visible change in plain words (see `git log`).
- **Docs:** `README.md` and this file describe the code as it is. If you change what is
  built, change them in the same commit.

## Current status

Pre-alpha. Phases 0–5 of the plan are implemented; §13's M2–M8 landed in October 2026
(hub transport, media, backups, push, TURN issuance, federation, multi-device). Nothing
has run on two physical devices yet — that is M1 and the next thing to do. Release numbers
and the toolchain pin are in `app_info.dart` and `FLUTTER_TOOLCHAIN`.
