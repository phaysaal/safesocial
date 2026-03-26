# Sphere

**Your data. Your network. Your rules.**

Sphere is a decentralized peer-to-peer social network where all data stays on your device. Built on [Veilid](https://veilid.com/) (a Rust P2P framework with onion routing) and [Flutter](https://flutter.dev/), Sphere requires no servers, no accounts, and performs no metadata collection. Your identity is a cryptographic keypair -- not an email address or phone number.

## Key Features

- **End-to-end encrypted messaging** -- all messages encrypted with XChaCha20-Poly1305 before leaving your device
- **Social feed and posts** -- publish updates to your contacts without a central server
- **Group chats** -- multi-writer DHT records with per-member message subkeys
- **Photo and video sharing** -- media stored in Veilid's block store, referenced by cryptographic hash
- **Cryptographic identity** -- Ed25519 keypair as your sole identity; no email, phone, or username required
- **Offline-first local storage** -- all data persisted locally; the network is used only for sync
- **Onion-routed privacy** -- Veilid private routes hide your IP from other participants and observers

## Architecture

```
+---------------------------------------------------+
|                   Flutter UI                       |
|  (screens, widgets, theme — Material Design 3)    |
+---------------------------------------------------+
|                  Dart Services                     |
|  VeilidService | IdentityService | ChatService     |
|  FeedService   | ContactService  | MediaService    |
+---------------------------------------------------+
|              veilid_support (FFI)                  |
|         Flutter <-> Rust bridge via Veilid         |
+---------------------------------------------------+
|              sphere_core (Rust)                  |
|  node | identity | schema | profile | contacts     |
|  messaging | groups | feed | media                 |
+---------------------------------------------------+
|                veilid-core (Rust)                  |
|  DHT | ProtectedStore | TableStore | BlockStore    |
|  Private Routes | Crypto | Network                 |
+---------------------------------------------------+
```

## Prerequisites

- **Rust toolchain** -- rustup with stable channel (edition 2021)
- **Flutter SDK** -- version 3.2.0 or higher
- **Veilid source** -- pulled automatically via `Cargo.toml` and `pubspec.yaml` git dependencies
- **Platform tools** -- Android SDK / Xcode for mobile builds, or Linux/macOS/Windows desktop toolchains

## Quick Start

```bash
# Build Rust core
cd sphere_core && cargo build

# Run Flutter app
cd sphere_app && flutter run
```

## Project Structure

```
sphere/
  sphere_core/          Rust crate — Veilid integration and P2P logic
    src/
      lib.rs              Core struct, error types, module declarations
      node.rs             Veilid node lifecycle and attachment state
      identity.rs         Ed25519 keypair generation, storage, import/export
      schema.rs           DHT record schemas and serialization helpers
  sphere_app/           Flutter application
    lib/
      main.dart           Entry point, service initialization, Provider setup
      app.dart            GoRouter configuration, bottom navigation shell
      services/           Dart service layer (Veilid, identity, chat, feed, contacts, media)
      screens/            UI screens (onboarding, chat, feed, contacts, profile, media)
      models/             Data models
      widgets/            Reusable UI components
      theme/              Material Design 3 dark theme
    assets/images/        Static image assets
  docs/                   Technical documentation
    architecture.md       Layered architecture and data flow
    protocol.md           Wire protocol and DHT schema specification
    threat_model.md       Threat model and security analysis
```

## Part of SafeSelf

Sphere is the second phase of the **SafeSelf** umbrella project:

1. **SeeSelf** (Phase 1) -- Personal data audit crawler that discovers what information about you is publicly available and models what an AI system could infer from it.
2. **Sphere** (Phase 2) -- This project. A decentralized social network that gives you a practical alternative to surveillance-based platforms.

The motivation: if SeeSelf shows you how exposed you are, Sphere gives you a way to take back control.

## License

TBD
