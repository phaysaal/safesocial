# Sphere Architecture

## Overview

Sphere uses a layered architecture with a clear separation between the Flutter UI, Dart service layer, and the Rust core that interfaces directly with Veilid.

```
+---------------------------------------------------+
|                   Flutter UI                       |
|  Screens, widgets, GoRouter navigation             |
|  State management via Provider/ChangeNotifier       |
+---------------------------------------------------+
          |  Dart method calls  |
+---------------------------------------------------+
|                  Dart Services                     |
|  VeilidService    — node lifecycle, state tracking  |
|  IdentityService  — keypair load/create, onboarding |
|  ChatService      — conversations, message send/recv|
|  FeedService      — post creation, feed aggregation  |
|  ContactService   — contact list, add/remove         |
|  MediaService     — photo/video capture and storage  |
+---------------------------------------------------+
          |  FFI via veilid_support  |
+---------------------------------------------------+
|              sphere_core (Rust)                  |
|  node.rs      — Veilid API start/stop/attach       |
|  identity.rs  — Ed25519 keypair management          |
|  schema.rs    — DHT schema definitions              |
|  profile.rs   — profile DHT record operations       |
|  contacts.rs  — contact exchange and storage        |
|  messaging.rs — encrypted message send/receive      |
|  groups.rs    — group chat management               |
|  feed.rs      — post publish/subscribe              |
|  media.rs     — block store operations              |
+---------------------------------------------------+
          |  Rust API calls  |
+---------------------------------------------------+
|                veilid-core                          |
|  Distributed Hash Table (DHT)                      |
|  ProtectedStore (encrypted secrets)                |
|  TableStore (structured local data)                |
|  BlockStore (content-addressed blobs)              |
|  Private Routes (onion routing)                    |
|  Crypto system (Ed25519, x25519, XChaCha20)        |
+---------------------------------------------------+
```

## Storage Model

Sphere uses four distinct Veilid storage subsystems, each serving a different purpose:

| Store | Purpose | Scope | Encryption | Examples |
|-------|---------|-------|------------|----------|
| **DHT (Distributed Hash Table)** | Shared, network-visible records | Global (replicated across Veilid peers) | Per-record owner/writer keys; values encrypted by application before storage | Profiles, conversations, posts, group metadata |
| **ProtectedStore** | Secrets that must never leave the device | Local only | OS keychain or Veilid's encrypted vault | Ed25519 secret key (`identity_secret`), Ed25519 public key (`identity_public`) |
| **TableStore** | Structured local data for fast lookup | Local only | Encrypted at rest by Veilid | Contact list, conversation index, feed subscriptions, local settings |
| **BlockStore** | Large content-addressed blobs | Local + optionally shared via DHT references | Content-addressed (hash-verified integrity) | Photos, videos, voice messages, file attachments |

### Why Four Stores?

- **DHT** is the only store visible to the network. It is used exclusively for data that needs to be shared with other users. All values written to DHT are encrypted by the application layer before storage.
- **ProtectedStore** is for cryptographic secrets. It uses the OS keychain where available (iOS Keychain, Android Keystore) and falls back to Veilid's own encrypted vault.
- **TableStore** is for local indexes and metadata that do not need to be shared. It provides fast key-value lookup without DHT latency.
- **BlockStore** is for large binary data. Media is stored as content-addressed blocks, and only the block hash is shared via DHT records or messages.

## Data Flow Diagrams

### Sending a Direct Message

```
Sender Device                        Veilid Network                    Recipient Device
     |                                     |                                |
     |  1. Compose message                 |                                |
     |  2. Serialize to JSON               |                                |
     |  3. Sign with sender Ed25519        |                                |
     |  4. Encrypt with shared secret      |                                |
     |     (x25519 DH + XChaCha20)         |                                |
     |  5. Write to conversation DHT       |                                |
     |     record (sender's subkey range)  |                                |
     |  ---------------------------------->|                                |
     |                                     |  6. DHT replicates to peers    |
     |                                     |  -------------------------------->|
     |                                     |                                |  7. Watch fires on
     |                                     |                                |     conversation record
     |                                     |                                |  8. Read sender's subkey
     |                                     |                                |  9. Decrypt with shared secret
     |                                     |                                | 10. Verify Ed25519 signature
     |                                     |                                | 11. Display in chat UI
```

### Creating and Publishing a Post

```
Author Device                        Veilid Network                    Contact's Device
     |                                     |                                |
     |  1. Author writes post content      |                                |
     |  2. If media attached:              |                                |
     |     a. Store in local BlockStore    |                                |
     |     b. Get block hash reference     |                                |
     |  3. Create post DHT record          |                                |
     |     (2 subkeys: content, reactions) |                                |
     |  4. Write content to subkey 0       |                                |
     |  5. Update profile's post list      |                                |
     |     in TableStore                   |                                |
     |  ---------------------------------->|                                |
     |                                     |  6. DHT replicates              |
     |                                     |  -------------------------------->|
     |                                     |                                |  7. Contact's feed service
     |                                     |                                |     polls known contacts'
     |                                     |                                |     post lists periodically
     |                                     |                                |  8. Discovers new post record
     |                                     |                                |  9. Reads content from DHT
     |                                     |                                | 10. Fetches media blocks
     |                                     |                                |     if referenced
     |                                     |                                | 11. Displays in feed
```

### Adding a Contact

```
User A                                                               User B
  |                                                                    |
  |  1. User A generates a contact-exchange                            |
  |     payload: {public_key, profile_dht_key}                        |
  |  2. Encodes as base64 string or QR code                           |
  |  ----------------------------------------------------------------->|
  |     (out-of-band: QR scan, paste, NFC, etc.)                      |
  |                                                                    |  3. User B decodes payload
  |                                                                    |  4. User B opens User A's
  |                                                                    |     profile DHT record
  |                                                                    |  5. User B verifies profile
  |                                                                    |  6. User B stores User A
  |                                                                    |     in local contacts
  |                                                                    |  7. User B generates own
  |                                                                    |     contact-exchange payload
  |  <-----------------------------------------------------------------|
  |     (out-of-band return)                                           |
  |  8. User A decodes, verifies,                                     |
  |     stores User B in contacts                                     |
  |  9. Both users can now create                                     |
  |     a conversation DHT record                                     |
  |     with both as writers                                          |
```

### Group Chat Message Flow

```
Member A                             Veilid Network                   Members B, C, ...
     |                                     |                                |
     |  1. Compose message                 |                                |
     |  2. Serialize, sign, encrypt        |                                |
     |     with group shared secret        |                                |
     |  3. Write to group DHT record       |                                |
     |     at member A's assigned subkey   |                                |
     |     (subkey = member_index + 2)     |                                |
     |  ---------------------------------->|                                |
     |                                     |  4. DHT replication             |
     |                                     |  -------------------------------->|
     |                                     |                                |  5. Each member watches
     |                                     |                                |     the group DHT record
     |                                     |                                |  6. Read new data from
     |                                     |                                |     member A's subkey
     |                                     |                                |  7. Decrypt, verify, display
```

## Crypto and Privacy

### Cryptographic Primitives

| Operation | Algorithm | Purpose |
|-----------|-----------|---------|
| Identity keypair | Ed25519 | Sign messages, prove ownership of DHT records |
| Key exchange | x25519 (Diffie-Hellman) | Derive shared secrets for conversation encryption |
| Symmetric encryption | XChaCha20-Poly1305 | Encrypt message and post content |
| Hashing | BLAKE3 | Content addressing in BlockStore |
| Network privacy | Veilid Private Routes | Onion routing to hide IP addresses |

### Identity

Each user's identity is a single Ed25519 keypair generated by Veilid's crypto system. The secret key is stored in the ProtectedStore (`identity_secret`), and the public key (`identity_public`) serves as the user's globally unique identifier. There is no username, email, or phone number involved.

The identity module (`identity.rs`) provides:
- `create_identity()` -- generate a new keypair and persist it
- `load_identity()` -- retrieve an existing keypair from ProtectedStore
- `get_or_create_identity()` -- load or create (the standard startup path)
- `identity_to_string()` / `identity_from_string()` -- export/import for backup
- `public_key_to_string()` -- encode the public key for sharing with contacts

### Private Routes

All DHT operations go through a Veilid `RoutingContext` created with `.with_privacy()`, which enables private routes (onion routing). This means:

1. The sender's IP address is hidden from the recipient and from intermediate nodes.
2. The recipient's IP address is hidden from the sender.
3. Intermediate relay nodes see only encrypted traffic and cannot determine the origin or destination.

The routing context is also configured with `.with_sequencing(Sequencing::PreferOrdered)` to maintain message ordering where possible.

## Module Responsibilities

### Rust Modules (`sphere_core`)

| Module | File | Responsibility |
|--------|------|----------------|
| `lib` | `lib.rs` | `SphereCore` struct (API, routing context, identity), error types, module declarations |
| `node` | `node.rs` | Veilid node lifecycle: start, stop, attachment state tracking, `wait_for_attach` |
| `identity` | `identity.rs` | Ed25519 keypair creation, loading, import/export via ProtectedStore |
| `schema` | `schema.rs` | DHT schema definitions (profile, conversation, post, group), JSON serialization helpers |
| `profile` | `profile.rs` | Read/write profile DHT records (display name, bio, avatar ref, status) |
| `contacts` | `contacts.rs` | Contact exchange payload generation, contact storage operations |
| `messaging` | `messaging.rs` | Message encryption, signing, DHT write/read for conversations |
| `groups` | `groups.rs` | Group creation, member management, group message operations |
| `feed` | `feed.rs` | Post creation, feed polling, reaction handling |
| `media` | `media.rs` | BlockStore put/get for photos, videos, and attachments |

### Dart Services (`sphere_app`)

| Service | Responsibility |
|---------|----------------|
| `VeilidService` | Manages the Veilid node lifecycle from Flutter; provides connection state as a `ChangeNotifier` |
| `IdentityService` | Wraps identity operations; tracks onboarding state; provides the user's public key to the UI |
| `ChatService` | Manages conversation list, message sending/receiving, conversation DHT record creation |
| `FeedService` | Post creation, feed aggregation from contacts, reaction submission |
| `ContactService` | Contact list management, contact exchange flow, contact persistence |
| `MediaService` | Camera/gallery integration, media compression, BlockStore upload/download |

## FFI Bridge Architecture

Sphere uses the `veilid_support` Flutter package (from the Veilid repository) as the FFI bridge between Dart and Rust:

```
Flutter (Dart)                      veilid_support                      Rust (veilid-core)
     |                                     |                                |
     |  Dart API calls                     |                                |
     |  (async, Future-based)              |                                |
     |  ---------------------------------->|                                |
     |                                     |  FFI marshaling               |
     |                                     |  (JSON serialization for       |
     |                                     |   complex types, raw bytes     |
     |                                     |   for simple values)           |
     |                                     |  -------------------------------->|
     |                                     |                                |  Rust execution
     |                                     |                                |  (tokio runtime)
     |                                     |  <--------------------------------|
     |                                     |  FFI unmarshaling              |
     |  <----------------------------------|                                |
     |  Dart receives result               |                                |
```

### Key Details

- **Platform libraries**: `sphere_core` compiles as a `cdylib` (shared library) and `staticlib` (for iOS). The Flutter app loads it at runtime via `veilid_support`.
- **Async model**: Dart `Future`s map to Rust `async` functions running on a Tokio runtime inside the native library.
- **Callbacks**: Veilid update events flow from Rust to Dart via a callback mechanism. The `UpdateCallback` type (`Arc<dyn Fn(VeilidUpdate) + Send + Sync>`) is registered at startup and delivers network state changes, DHT value changes, and other events.
- **Serialization**: Complex types cross the FFI boundary as JSON strings. The `schema.rs` module provides `serialize()` and `deserialize()` helpers using `serde_json`.
- **Protobuf (future)**: The Cargo.toml includes `prost` and `prost-build` dependencies, indicating a planned migration from JSON to Protocol Buffers for wire format efficiency.
