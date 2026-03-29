# Spheres — Architecture Weaknesses & Missing Implementations

**Date:** 2026-03-29
**Reviewed by:** Code analysis (source files only, no markdown)
**Scope:** `safesocial_app/lib/`, `safesocial_core/src/`, `relay/`

---

## Part 1: Architectural Weaknesses

### 1. Encryption Is Not Actually Working (Critical)

The current encryption stack does not deliver the privacy it promises.

**a) XOR "encryption" in place of XChaCha20-Poly1305**

`safesocial_app/lib/services/crypto_service.dart:16–41`

Messages are encrypted with XOR + repeating key and a random 16-byte nonce. XOR with a repeating key is trivially broken: XORing any two ciphertexts encrypted with the same key cancels the key out, revealing a combination of the two plaintexts. This is not an authenticated cipher and provides no integrity guarantee.

**b) Shared key is not a DH exchange — it is publicly derivable**

`safesocial_app/lib/services/crypto_service.dart:65–70`

The "shared key" is computed as `SHA256(sorted(pubkeyA, pubkeyB))`. Both parties can compute it from public information alone. Any third party who knows both users' public keys can also compute the key and decrypt all messages. There is no Diffie-Hellman exchange.

**c) Double Ratchet is a stub — encrypt/decrypt return plaintext**

`safesocial_core/src/ratchet.rs:54–63` and `:67–75`

`encrypt_ratcheted()` and `decrypt_ratcheted()` both return the input bytes unchanged. Forward secrecy does not exist. Comments acknowledge this: `// For now, we return the plaintext to keep the flow working.`

**d) FFI crypto functions return hardcoded placeholders**

`safesocial_core/src/ffi.rs:52–61` — `spheres_create_identity()` returns a status message, not an actual keypair.
`safesocial_core/src/ffi.rs:92–113` — `spheres_export_identity()` returns `"placeholder_encrypted_blob"`.
`safesocial_core/src/ffi.rs:130–143` — `spheres_create_vault()` returns `"placeholder_vault_blob"`.
`safesocial_core/src/ffi.rs:161–178` — `spheres_create_group_key()` returns `"placeholder_base64_group_key"`.
`safesocial_core/src/ffi.rs:181–198` — `spheres_encrypt_group_msg()` returns `"placeholder_encrypted_msg"`.

The Rust crypto core is scaffolded but not connected to real operations.

---

### 2. Messages Stored Unencrypted Locally (Critical)

`safesocial_app/lib/services/chat_service.dart:135–142`

Messages are persisted to `SharedPreferences` as plain JSON without any encryption. On Android, SharedPreferences are accessible via ADB backup on non-rooted devices. On iOS, they are included in unencrypted iTunes backups unless the user enables encrypted backups. Anyone with physical device access or a backup file can read the full message history.

---

### 3. DHT Messaging Path Not Implemented (High)

`safesocial_app/lib/services/chat_service.dart:81–85`

The DHT transport path in `sendMessage()` is a comment:
```dart
// DHT implementation would go here
```
The app currently depends entirely on the WebSocket relay for message delivery. The core P2P/decentralized promise is not functional.

---

### 4. Relay Room ID Has Collision Risk and Is Predictable (High)

`safesocial_app/lib/services/crypto_service.dart:74–89`

The relay room ID is derived by:
1. Computing SHA256 of the two public keys + salt
2. Collapsing the result into a **32-bit integer** via a simple hash loop (`& 0xFFFFFFFF`)
3. Encoding as base36

This produces only ~4 billion possible room IDs across all users globally. The collision probability grows quickly with user count.

Additionally, the salt `'spheres-relay-v2-salt-secret-'` is hardcoded in source code. Any attacker who knows two users' public keys (which are public by design) can compute their room ID and join the WebSocket room to observe or inject relay traffic.

---

### 5. Centralized Relay Is a Single Point of Failure (High)

`safesocial_app/lib/services/relay_service.dart:11–12`

Only two hardcoded relay URLs exist:
- `wss://relay.spheres.dev` (primary)
- `wss://spheres-relay.phaysaal.workers.dev` (fallback)

If both are unavailable (outage, DNS block, government censorship), real-time messaging fails completely. There is no peer discovery mechanism to find alternative relays, and no user-configurable relay URL.

The reconnect logic (`relay_service.dart:63–66`) retries the same URLs indefinitely with a 5-second delay, with no circuit-breaker or user notification.

---

### 6. WebRTC Leaks IP Addresses to Google (Medium)

`safesocial_app/lib/services/call_service.dart`

Google's public STUN servers (`stun.l.google.com`) are used for WebRTC NAT traversal. This means Google observes the IP addresses of both call participants at call setup time — a significant privacy violation for an app explicitly built around privacy. No TURN servers are configured; calls behind strict NAT will fail silently.

---

### 7. No Group Message Forward Secrecy (Medium)

`safesocial_core/src/ffi.rs:161–178`, `safesocial_core/src/groups.rs`

Groups use a single static symmetric key per group, generated once at creation and never rotated. If the key is ever compromised, all past and future group messages are exposed. Unlike 1:1 messaging (which intends Double Ratchet), there is no ratcheting or epoch-based key rotation for groups.

---

### 8. Media Hashing Uses Non-Cryptographic Hash (Medium)

`safesocial_core/src/media.rs:35–51`

`compute_block_id()` uses Rust's `DefaultHasher` (SipHash, not cryptographic) to produce content-addressed block IDs. `DefaultHasher` is explicitly documented as unsuitable for security purposes and produces different values across Rust versions. Two different media files could produce the same block ID (collision), causing data corruption.

---

### 9. Veilid Update Callback Is a No-Op in FFI (Low-Medium)

`safesocial_core/src/ffi.rs:33`

```rust
let callback = Arc::new(|_| {});
```

All Veilid network events (DHT record changes, peer state, routing updates) are silently discarded in the Rust core. Reactive DHT operations (receiving messages, detecting contact online status, feed updates) will not trigger any notifications from the Rust layer.

Note: `VeilidService` in Dart (`veilid_service.dart:158–191`) does handle updates from the Dart Veilid binding correctly, but the Rust core's own Veilid instance has no update handling.

---

### 10. Message Ordering Relies on Device Clocks (Low)

`safesocial_app/lib/services/chat_service.dart:107`

Messages are sorted by `timestamp` which is set client-side (`DateTime.now()`). With dual-path delivery (relay + DHT), messages from different devices with skewed clocks will appear out of order. There are no sequence numbers or vector clocks. The deduplication by UUID (`chat_service.dart:105`) prevents duplicates but cannot fix ordering.

---

## Part 2: Missing Implementations (Stubs & TODOs)

### Rust Core (`safesocial_core/src/`)

| File | Line(s) | What is missing |
|------|---------|-----------------|
| `ffi.rs` | 53–61 | `spheres_create_identity()` — calls identity module but returns a status message, not the actual keypair |
| `ffi.rs` | 92–113 | `spheres_export_identity()` — returns `"placeholder_encrypted_blob"` instead of encrypted identity |
| `ffi.rs` | 116–128 | `spheres_import_identity()` — returns success but does nothing |
| `ffi.rs` | 130–143 | `spheres_create_vault()` — returns `"placeholder_vault_blob"` |
| `ffi.rs` | 145–158 | `spheres_unlock_vault()` — returns empty payload `"{}"` |
| `ffi.rs` | 161–178 | `spheres_create_group_key()` — returns `"placeholder_base64_group_key"` |
| `ffi.rs` | 181–198 | `spheres_encrypt_group_msg()` — returns `"placeholder_encrypted_msg"` |
| `ffi.rs` | 33 | Veilid update callback is `Arc::new(\|_\| {})` — no event handling |
| `ratchet.rs` | 54–63 | `encrypt_ratcheted()` — returns plaintext unchanged, no ratchet logic |
| `ratchet.rs` | 67–75 | `decrypt_ratcheted()` — returns ciphertext unchanged, no ratchet logic |
| `ratchet.rs` | 79–83 | `ed25519_to_x25519()` — returns `[0u8; 32]` placeholder |
| `media.rs` | 35–51 | `compute_block_id()` — uses non-cryptographic `DefaultHasher` instead of BLAKE3/SHA256 |
| `media.rs` | 1–6 | Entire module uses TableStore as a temporary backend; Block Store integration pending |

### Flutter/Dart App (`safesocial_app/lib/`)

| File | Line(s) | What is missing |
|------|---------|-----------------|
| `services/chat_service.dart` | 81–85 | DHT message send path — `// DHT implementation would go here` |
| `services/chat_service.dart` | 88–90 | `handleValueChange()` — DHT update handler body is empty |
| `services/crypto_service.dart` | 16–41 | Real encryption (XChaCha20-Poly1305) — currently XOR with repeating key |
| `services/crypto_service.dart` | 65–70 | Real DH key exchange — currently `SHA256(pubkeyA + pubkeyB)` |
| `screens/onboarding/onboarding_screen.dart` | 142 | "Import existing identity" button — `// TODO: Implement` |
| `screens/media/media_viewer_screen.dart` | 28 | Share via Veilid — `// TODO: Implement sharing via Veilid` |
| `screens/media/media_viewer_screen.dart` | 38 | Save to gallery — `// TODO: Implement download/save to gallery` |

### Summary by Priority

| Priority | Item | Files |
|----------|------|-------|
| **P0** | Replace XOR with XChaCha20-Poly1305 | `crypto_service.dart` |
| **P0** | Implement real DH key exchange | `crypto_service.dart`, `ffi.rs` |
| **P0** | Implement Double Ratchet | `ratchet.rs`, `ffi.rs` |
| **P0** | Encrypt local message storage | `chat_service.dart` |
| **P1** | Implement DHT message send/receive | `chat_service.dart` |
| **P1** | Connect `spheres_create_identity()` to `identity.rs` | `ffi.rs` |
| **P1** | Implement identity export/import vault | `ffi.rs` |
| **P1** | Implement group key generation and encryption | `ffi.rs`, `groups.rs` |
| **P1** | Fix relay room ID to use full SHA256 | `crypto_service.dart` |
| **P2** | Replace Google STUN with privacy-respecting servers | `call_service.dart` |
| **P2** | Replace `DefaultHasher` with BLAKE3 for media IDs | `media.rs` |
| **P2** | Implement Veilid update callback in Rust FFI | `ffi.rs` |
| **P2** | Migrate Block Store from TableStore temp backend | `media.rs` |
| **P3** | Implement identity import UI | `onboarding_screen.dart` |
| **P3** | Implement media share/save actions | `media_viewer_screen.dart` |
