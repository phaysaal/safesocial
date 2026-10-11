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
  facades; all share the hub. A publish counts as sent only when the relay's `sent` frame
  comes back. The relay keeps every message until an HTTP drain acknowledges it, and a
  mailbox is shared by both parties, so the hub remembers digests of what it delivered and
  published and a drain acknowledges those without delivering them again. Every plain
  HTTP call goes through `relayHttp`, which moves to the workers.dev name when the custom
  domain does not answer at all. A contact on another relay is reached by a signed HTTP
  post to that relay (federation); the host comes from their bundle.
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
  they fall back to public STUN and say so. The operator's coturn runs on the Scaleway
  instance beside ntfy (`turn.spheres.dev`, UDP/TCP 3478 and TLS 5349 with a Let's
  Encrypt certificate Caddy renews; secrets `TURN_SECRET`/`TURN_URLS` on the Worker). A "relay every call through TURN" switch under Call Servers sets the ICE
  policy to relay only; that is how the TURN path was proven on 11 October 2026.
- **Hub identity.** The hub id in the socket URL is minted once per install and kept in
  plain `SharedPreferences`, because a mailbox holds one subscriber slot per hub and a
  fresh id per process filled the slots with dead hubs within a day. The relay evicts
  the oldest subscriber when a mailbox is full rather than refusing the newcomer.
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
  feed carries `post_edit`, `post_pin`, `post_settings` (comments off), `event_rsvp`,
  `post_vote`, `coauthor_accept`, `report`, `comment`, `reaction`, and on comments
  `comment_edit` (earlier text kept), `comment_delete`, `comment_hide`, `comment_pin`,
  `comment_react`. Who may do what is decided by who signed: edits by the comment's
  author, hide and pin by the post's author or a sphere admin, delete by either, a
  closed post takes no comment but its author's. Which posts notify us (follow, mute)
  is local to the device. Every one is attributed to the signed sender and, where it matters, checked
  against sphere roles on receipt. Add a new kind by extending the model, the sender, the
  switch in the receiver, and `describeMessage` for notifications.
- **Profiles.** `UserProfile` carries name, bio, picture, birthday, a structured
  `ProfileAbout` (pronouns, nickname, pronunciation, work, education, city, hometown,
  relationship and partner, family, languages, websites, hobbies, quotes, life events),
  cover and featured photos, a temporary-picture timer, a legacy contact, pinned posts,
  and an audience per field (`FieldAudience`: all contacts, named spheres, or only me).
  The `profile` envelope is built per contact by `ProfileSharing.payloadFor`, which cuts
  the profile to what that contact's shared spheres allow; the receiver treats the
  message as the sender's whole view and drops any field it no longer carries, while a
  malformed field is ignored. Only the legacy contact is told they are one. "View as" on
  the profile screen renders exactly that cut. Photos travel as encrypted blobs.
- **Invite links** are `spheres://join?s=&t=&via=&n=`; the request goes to the admin's open
  inbox and approval makes the requester a contact and a member in one step.
- **Not built, by decision:** an SFU for large group calls (mesh only), any pixel-level
  classifier (nudity or AI-image detection; the origin score reads metadata only),
  communities as spheres of spheres, pending-post approval queues, story drawing.
- **Still open:** APNs, reproducible-build proof, external audit. See the plan's §13.
  The project's coturn and ntfy both run on the Scaleway instance under their own names
  with TLS; a phone whose ntfy app points at `https://ntfy.spheres.dev` is woken through
  it (the Samsung is, the Motorola still uses the public ntfy.sh until its ntfy app is
  pointed over). Every M1 item has now run on hardware: background wakes through ntfy,
  restoring an encrypted backup from Settings and a call forced through TURN all passed
  on 11 October 2026.
- Directory names: the app is `safesocial_app/`, the Dart package `spheres_app`, the
  product Spheres.

### House rule

**A stub must never report success.** Code that cannot do its job throws or returns an
explicit error. Silent placeholders are what turned incomplete work in this repo into
invisible incomplete work. If a feature is not finished, the UI says so.

### Second rule

**The message path has run on real hardware once** (11 October 2026: a Samsung S23+ on
Android 16, a Motorola Edge 20 Fusion on Android 13 over Wi-Fi adb, and a Samsung tablet
as a third party; two devices linked to one identity, a message from the third landing on
both and a reply from either reaching the third and the sibling). Direct
chat, media, offline delivery, spheres, posts and sphere chat worked; the first call
crashed the receiver and a half-dead socket lost sphere messages, both fixed the same
day. A ntfy wake brought a stopped app back with a notification, and an encrypted
backup restored from Settings (which had never asked for the passphrase; fixed). When a change touches the message path, say so in the commit and prefer changes
that a test can cover. Emulator pairs cannot
scan QR codes; debug builds print the invite link instead (see `identity_service.dart`).

## Build & run

### Flutter app (`safesocial_app/`)
```bash
flutter pub get
flutter analyze --no-fatal-infos   # errors and warnings must stay at zero
flutter test                       # 668 tests in 56 files under test/{crypto,models,screens,services}
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

### Edge box (`infra/`)
coturn and ntfy on the Scaleway instance, as code: `setup.sh` (run on the box with
`PUBLIC_IP`, `TURN_HOST`, `NTFY_HOST`) writes the configs from the templates there and
`check.sh` proves STUN, TURN-over-TLS and ntfy from outside. The TURN secret lives in
`/etc/turnserver.conf` on the box and as the Worker secret `TURN_SECRET`; it is not in
the repo. Change a config there, not by hand on the box.

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
| `SharedPreferences` plaintext | `theme_mode`, relay host, call config, the hub id — nothing secret |
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
(hub transport, media, backups, push, TURN issuance, federation, multi-device). The first
two-phone session (M1) ran on 11 October 2026 and its findings are being fixed; the rest
of M1 is listed under "Still open" above. Release numbers
and the toolchain pin are in `app_info.dart` and `FLUTTER_TOOLCHAIN`.
