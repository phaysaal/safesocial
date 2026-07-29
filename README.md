# Spheres

**Your data. Your network. Your rules.**

Spheres is an in-development social network built so that no content has a public
audience: everything lives inside a *sphere*, a named group with an explicit
membership list. Your identity is a cryptographic keypair — not an email address or
phone number.

> ## ⚠️ Pre-alpha — unaudited
>
> Messages, sphere posts and call signalling are now genuinely encrypted
> (XChaCha20-Poly1305 with X25519 key agreement, everything signed), and the relay
> derives its addresses from shared secrets so it cannot tell who talks to whom.
> What is still true:
>
> - **Nothing here has been independently audited**, and none of it has been
>   exercised on real devices end to end.
> - **Local storage is unencrypted.** Message history and sphere keys sit in
>   SharedPreferences; only the identity key is in the platform keystore.
> - **Albums are still sent in the clear**, and there is no peer-to-peer
>   networking — all traffic goes through one relay, which sees timing and
>   approximate message size.
> - **Several features are disabled** because they reported success without working:
>   encrypted identity export/import, social recovery, and multi-device linking.
>
> The plan for closing these gaps is in [`docs/rebuild_plan.md`](docs/rebuild_plan.md),
> which also records why Veilid was evaluated and set aside as a transport for now.

## Planned model

The organising idea is that **everything is a sphere**. A direct message is a sphere
with two members; a group chat, a shared album, and a "close friends" audience are all
the same primitive with different presentation. There is no "everyone" and no public
profile — content that is not addressed to a sphere does not exist.

## Current state

| Area | Status |
|---|---|
| Identity (Ed25519 keypair, local generation, secure storage) | Working |
| Contacts, QR exchange, local contact management | Working |
| Spheres (member-scoped groups) | Working: create, invite, accept, remove with key rotation |
| 1:1 chat | Encrypted and ratcheted, with a durable outbox and delivery receipts |
| Feed, posts, stories, reactions | Encrypted and scoped to a sphere |
| Photo sharing | Works in the feed; chat and album media still send local file paths |
| Voice/video calls | 1:1 works via WebRTC, signalling encrypted; group calls still broken |
| EXIF/GPS stripping on images | Working |
| Encrypted backup, identity export, social recovery, device linking | Disabled — not implemented |
| Veilid / DHT / peer-to-peer | Not implemented |

## Architecture (as built)

```
+---------------------------------------------------+
|                   Flutter UI                       |
|  (screens, widgets, theme — Material Design 3)     |
+---------------------------------------------------+
|                  Dart Services                     |
|  IdentityService | ChatService   | FeedService     |
|  ContactService  | SphereService | CallService     |
|  MediaService    | RelayService  | OutboxService   |
+---------------------------------------------------+
|            Crypto (lib/crypto/)                    |
|  X25519 + HKDF + XChaCha20-Poly1305, Ed25519 sigs  |
|  pairwise sessions · sphere keyring · envelopes    |
+---------------------------------------------------+
|              Cloudflare Worker relay               |
|  Secret-derived mailboxes + offline queue + prekey |
+---------------------------------------------------+

safesocial_core/ (Rust) exists but is dormant: it is not compiled
into the app and nothing calls it at runtime.
```

## Prerequisites

- **Flutter SDK** -- version 3.8 or higher (the app is pure Dart; no Rust toolchain needed)
- **Platform tools** -- Android SDK / Xcode for mobile builds, or Linux/macOS/Windows desktop toolchains
- **Rust toolchain** -- only if you intend to work on the dormant `safesocial_core` crate

## Quick Start

```bash
cd safesocial_app
flutter pub get
flutter run
```

Release builds require `safesocial_app/android/key.properties` with your signing
keystore details. Without it the release build fails by design — it must never fall
back to the public Android debug key.

## Project Structure

```
safesocial/
  safesocial_app/         Flutter application (this is what ships)
    lib/
      main.dart           Entry point, service initialization, Provider setup
      app.dart            GoRouter configuration, bottom navigation shell
      app_info.dart       Version strings shown in the UI
      services/           Dart service layer (identity, chat, feed, contacts, relay, media)
      screens/            UI screens (onboarding, chat, feed, contacts, profile, media)
      models/             Data models
      widgets/            Reusable UI components
      theme/              Material Design 3 theme
    test/                 Unit tests
    assets/images/        Static image assets
  relay/                  Cloudflare Worker — WebSocket rooms and offline mailbox
  safesocial_core/        Rust crate — dormant, not built into the app
  landing/                Project website
  docs/                   Technical documentation
    rebuild_plan.md       The current plan — start here
    architecture_weaknesses.md  Known defects in the shipping build
    privacy_protocol.md   The cryptographic design, now largely implemented
    protocol.md           Original Veilid wire protocol spec (aspirational)
    threat_model.md       Threat model (describes the intended system)
```

> Note on the docs: `architecture.md`, `protocol.md`, and `threat_model.md` describe the
> originally intended Veilid-based system, not what is built today. They are kept as
> design references. `rebuild_plan.md` is the authoritative current plan.

## Part of SafeSelf

Spheres is the second phase of the **SafeSelf** umbrella project:

1. **SeeSelf** (Phase 1) -- Personal data audit crawler that discovers what information about you is publicly available and models what an AI system could infer from it.
2. **Spheres** (Phase 2) -- This project. A social network with no public audience, intended as a practical alternative to surveillance-based platforms.

The motivation: if SeeSelf shows you how exposed you are, Spheres gives you a way to take back control.

## License

TBD
