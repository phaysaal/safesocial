# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spheres is an in-development social network in which no content has a public audience —
everything is scoped to a *sphere* (a named group with an explicit membership list).
Identity is an Ed25519 keypair. Part of the SafeSelf umbrella project (Phase 2, after
SeeSelf).

**Read `docs/rebuild_plan.md` before making architectural changes.** It is the
authoritative plan and records decisions (notably: Veilid was evaluated and set aside
as a transport; the relay stays).

## Ground truth about the current build

Much of the older documentation describes a system that was never wired up. What is
actually true today:

- **The app is 100% Dart over a Cloudflare Worker relay.** There is no Veilid, no DHT,
  and no peer-to-peer networking anywhere in `safesocial_app/lib/`.
- **`safesocial_core/` (Rust) is dormant.** It is not compiled into the app, no `.so`
  is bundled, and `RustCoreService` fails to initialise because it binds a symbol that
  does not exist. Do not add features that depend on it.
- **`crypto_service.dart` is a placeholder cipher** (XOR, key derived from public keys)
  — not encryption. Replacing it is Phase 1 of the plan, using the `cryptography`
  package in Dart. No FFI is required.
- **Encrypted backup/export, social recovery, and device linking are disabled** because
  they reported success while doing nothing.
- Directory names differ from older docs: the crate is `safesocial_core/` (not
  `spheres_core/`) and the app is `safesocial_app/` (not `spheres_app/`), while the
  Dart package name is still `spheres_app`.

### House rule

**A stub must never report success.** Code that cannot do its job throws or returns an
explicit error. Silent placeholders are what turned incomplete work in this repo into
invisible incomplete work.

## Build & Run Commands

### Flutter app (`safesocial_app/`)
```bash
flutter pub get                  # Fetch dependencies
flutter analyze --no-fatal-infos # Lint — errors and warnings must stay at zero
flutter test                     # Run tests
flutter test test/some_test.dart # Run a single test file
flutter run                      # Run on connected device/emulator
flutter build apk --debug        # Android debug build
flutter build apk                # Android release — needs android/key.properties
```

### Rust core (`safesocial_core/`) — dormant
```bash
cargo check                      # Type-check (slow: pulls veilid-core)
cargo test                       # No tests exist yet
```
Not part of CI and not built into the app. See `docs/rebuild_plan.md` §5.

### Relay (`relay/`)
```bash
node --check worker.js           # Syntax check
npx wrangler dev                 # Local development server
npx wrangler deploy              # Deploy to Cloudflare
```

## Architecture (as built)

```
Flutter UI (Provider/ChangeNotifier + GoRouter)
    ↓ Dart method calls
Dart Services (IdentityService, ChatService, FeedService, ContactService,
               GroupService, AlbumService, CallService, MediaService)
    ↓ WebSocket + HTTPS
relay/worker.js (Cloudflare Worker + Durable Objects)
    — WebSocket rooms for live delivery
    — per-room mailbox for offline delivery (30-day retention)
    — /state/<pubkey>/<key> KV, currently used only for profiles
```

### Flutter app (`safesocial_app/lib/`)
- `main.dart` — Entry point, MultiProvider setup, startup service wiring
- `app.dart` — GoRouter config, bottom navigation shell
- `app_info.dart` — Version strings shown in the UI
- `services/` — Dart service layer, each service is a `ChangeNotifier` consumed via Provider
- `screens/` — UI screens (onboarding, chat, feed, contacts, profile, groups, media)
- `models/` — Data models with `Equatable`, `fromJson`/`toJson` serialization
- `widgets/` — Reusable components (avatar, message_bubble, post_card, media_preview)
- `theme/app_theme.dart` — Material Design 3 theme

Each service currently owns its own `RelayService` instance (seven in total).
Consolidating these into one multiplexed connection is Phase 2 of the plan.

## Storage Model

There is no database. Everything is local:

| Store | Contents |
|-------|----------|
| **`flutter_secure_storage`** | Only `spheres_identity_secret` (the Ed25519 secret key) |
| **`SharedPreferences`** | Everything else, as plaintext JSON: `spheres_identity_profile`, `spheres_identity_pubkey`, `spheres_contacts`, `spheres_conversations`, `spheres_msgs_<pubkey>`, `spheres_groups`, `spheres_group_msgs_<id>`, `spheres_feed_posts` (capped at 100), `spheres_hidden_posts`, `spheres_rings`, `spheres_albums`, `theme_mode` |
| **App documents dir** | `backups/*.spheres`, decoded inbound media, recorded voice notes |

Moving to SQLite encrypted at rest is Phase 2 of the plan.

## Key Conventions

- **Dart state**: Provider with `ChangeNotifier` — services are injected at app root
- **Dart navigation**: GoRouter with named routes
- **Wire format**: JSON over the relay; each message carries a `type` field (except 1:1
  chat, which sends a bare `Message` — an inconsistency to fix)
- **No stub reports success** — see the house rule above

## Current Status

Pre-alpha. Messaging works but is unreliable (no outbox, no acks, no dedup) and is not
securely encrypted. The near-term sequence is Phase 1 (real cryptography in Dart) then
Phase 2 (reliable, private delivery). See `docs/rebuild_plan.md`.
