# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sphere is a decentralized P2P social network built on **Veilid** (Rust P2P framework with onion routing) and **Flutter**. No servers, no accounts, no metadata collection. Identity is a cryptographic Ed25519 keypair. Part of the SafeSelf umbrella project (Phase 2, after SeeSelf).

## Build & Run Commands

### Rust core (`sphere_core/`)
```bash
cargo build                      # Debug build (from workspace root or sphere_core/)
cargo build --release            # Release build
cargo test                       # Run all tests
cargo test <test_name>           # Run a single test
cargo check                      # Type-check without building
```

### Flutter app (`sphere_app/`)
```bash
flutter pub get                  # Fetch dependencies
flutter analyze                  # Lint (uses analysis_options.yaml with flutter_lints)
flutter test                     # Run widget tests
flutter test test/some_test.dart # Run a single test file
flutter run                      # Run on connected device/emulator
flutter build apk               # Android build
flutter build ipa                # iOS build
```

## Architecture

Two-crate monorepo: Rust core + Flutter app, connected via FFI (`veilid_support` package).

```
Flutter UI (Provider/ChangeNotifier + GoRouter)
    ↓ Dart method calls
Dart Services (VeilidService, IdentityService, ChatService, FeedService, ContactService, MediaService, GroupService)
    ↓ FFI via veilid_support (JSON serialization across boundary)
sphere_core (Rust) — node, identity, schema, profile, contacts, messaging, groups, feed, media
    ↓ Rust API calls
veilid-core — DHT, ProtectedStore, TableStore, BlockStore, Private Routes, Crypto
```

### Rust core (`sphere_core/src/`)
- `lib.rs` — `SphereCore` struct (holds VeilidAPI, RoutingContext, KeyPair), `SphereError` enum via `thiserror`
- `node.rs` — Veilid node start/stop/attach lifecycle, state tracking
- `identity.rs` — Ed25519 keypair generation/storage/import/export via ProtectedStore
- `schema.rs` — DHT record schema definitions, JSON serialization helpers
- `profile.rs` — Profile DHT ops (subkeys: info=0, avatar=1, status=2)
- `contacts.rs` — Contact exchange payload, contact storage
- `messaging.rs` — Message encryption (XChaCha20-Poly1305), signing (Ed25519), DHT read/write
- `groups.rs` — Group creation, member management, per-member subkey ranges (subkey = member_index + 2)
- `feed.rs` — Post publish/subscribe, reactions (post DHT: content=subkey 0, reactions=subkey 1)
- `media.rs` — BlockStore put/get for photos/videos

### Flutter app (`sphere_app/lib/`)
- `main.dart` — Entry point, MultiProvider setup for all services
- `app.dart` — GoRouter config, bottom navigation shell
- `services/` — Dart service layer, each service is a `ChangeNotifier` consumed via Provider
- `screens/` — UI screens (onboarding, chat, feed, contacts, profile, groups, media)
- `models/` — Data models with `Equatable`, `fromJson`/`toJson` serialization
- `widgets/` — Reusable components (avatar, message_bubble, post_card, media_preview)
- `theme/dark_theme.dart` — Material Design 3 dark theme

## Storage Model (No Traditional Database)

All persistence goes through Veilid's four-tier storage:

| Store | Scope | Purpose |
|-------|-------|---------|
| **DHT** | Global (replicated) | Shared data: profiles, conversations, posts, groups |
| **ProtectedStore** | Local only | Secrets: Ed25519 keypair (`identity_secret`, `identity_public`) |
| **TableStore** | Local only | Indexes: contact list, conversation index, feed subscriptions |
| **BlockStore** | Local + shared | Large blobs: photos, videos, attachments (content-addressed by hash) |

## Key Conventions

- **Rust error handling**: Custom `SphereError` enum with `thiserror`; `Result<T>` type alias throughout
- **Rust async**: All I/O uses Tokio; Veilid API is fully async
- **Rust logging**: `tracing` crate (`info!`, `debug!`, `error!`)
- **Dart state**: Provider with `ChangeNotifier` — services are injected at app root
- **Dart navigation**: GoRouter with named routes
- **DHT records**: Identified by `RecordKey`, data split into semantic subkeys
- **Privacy**: All DHT operations go through `RoutingContext` with `.with_privacy()` (onion routing)
- **Encryption**: Application-layer encryption before DHT writes; no plaintext secrets on the network

## Current Status

The FFI bridge between Flutter and Rust is **in progress** — Dart services currently contain stubs/TODOs where Veilid integration will connect. Protobuf migration (prost) is planned but not yet active; current wire format is JSON via serde.
