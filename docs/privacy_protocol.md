# Spheres Privacy Protocol — Lattice-Based Content Encryption

**Version:** 1.0
**Status:** Design specification
**Date:** 2026-03-26

## 1. Overview

Every piece of content in Spheres (messages, photos, videos, posts) is encrypted at rest and in transit. Content is decrypted only in-memory within the app — plaintext never touches persistent storage. Each content item has a privacy level that determines who holds the decryption key.

### Privacy Levels

| Level | Description | Key Holders |
|-------|-------------|-------------|
| `self` | Only the creator can see it | Creator's device key only |
| `individual` | Shared with one specific person | Creator + one recipient |
| `group` | Shared with a defined group | Creator + all group members |
| `public` | Anyone can see it | No encryption (plaintext on DHT) |

### Core Guarantees

1. **Content is always encrypted** (except `public`) before leaving the app boundary
2. **Per-content unique key** — every item gets a fresh random symmetric key
3. **No-forward enforcement** — the app never exports decrypted restricted content; receivers cannot reshare to unauthorized parties
4. **Key separation** — each pairwise relationship and each group has its own key material
5. **Forward secrecy** — compromising a long-term key does not decrypt past content (each content key is independent)
6. **Revocation** — removing a member from a group rotates the group key; old content remains accessible to those who had it, new content is inaccessible
7. **Secure rendering** — decrypted media is rendered in a secure widget (Android FLAG_SECURE, iOS screenshot prevention) and never written to disk in plaintext

---

## 2. Cryptographic Primitives

| Operation | Algorithm | Purpose |
|-----------|-----------|---------|
| Identity keypair | Ed25519 | Sign content, prove authorship |
| Key exchange | x25519 Diffie-Hellman | Derive pairwise shared secrets |
| Content encryption | XChaCha20-Poly1305 | Encrypt content with content key |
| Key wrapping | XChaCha20-Poly1305 | Encrypt content key for recipients |
| Key derivation | HKDF-SHA256 | Derive sub-keys from shared secrets |
| Group key agreement | Pairwise DH + key tree | Derive group symmetric key |
| Content hashing | BLAKE3 | Content addressing in BlockStore |
| Nonce generation | Random 192-bit | Unique per encryption operation |

All primitives are provided by Veilid's crypto system (`veilid-core` CryptoSystem API).

---

## 3. Key Hierarchy

```
Identity KeyPair (Ed25519)
├── Public Key (shared with contacts)
└── Secret Key (never leaves device, stored in ProtectedStore)

Per-Contact Pairwise Key
├── shared_secret = x25519_DH(my_secret, their_public)
├── send_key = HKDF(shared_secret, "spheres-send-v1", my_public)
└── recv_key = HKDF(shared_secret, "spheres-recv-v1", their_public)

Per-Group Key
├── group_key = HKDF(combined_pairwise_secrets, "spheres-group-v1", group_id)
├── Rotated when membership changes
└── group_key_epoch tracks version (monotonically increasing)

Per-Content Key
├── content_key = random_256_bits()
├── Unique per content item (photo, video, post, message)
└── Encrypted (wrapped) separately for each authorized key holder
```

---

## 4. Content Encryption Protocol

### 4.1 Creating Encrypted Content

```
Input:
  - content: raw bytes (photo, video, text)
  - privacy_level: self | individual(recipient) | group(group_id) | public
  - creator_keypair: Ed25519 KeyPair
  - mime_type: string

Steps:

  1. IF privacy_level == public:
       a. Sign content: signature = Ed25519_sign(creator_secret, content)
       b. Store plaintext + signature on DHT
       c. Return content_ref = {record_key, signature, privacy: "public"}
       d. DONE — no encryption needed

  2. Generate content_key = random(32 bytes)  // 256-bit AES-equivalent

  3. Generate nonce = random(24 bytes)  // 192-bit for XChaCha20

  4. encrypted_content = XChaCha20Poly1305_encrypt(
       key = content_key,
       nonce = nonce,
       plaintext = content,
       aad = encode(mime_type, creator_public_key, privacy_level)
     )

  5. content_hash = BLAKE3(encrypted_content)

  6. Store encrypted_content in BlockStore (content-addressed by content_hash)

  7. Build access_control envelope:

     IF privacy_level == self:
       device_key = HKDF(creator_secret, "spheres-device-v1", device_id)
       wrapped_key = XChaCha20Poly1305_encrypt(
         key = device_key,
         nonce = random(24),
         plaintext = content_key
       )
       envelope = {
         privacy: "self",
         content_hash,
         nonce,
         mime_type,
         wrapped_keys: [{
           recipient: creator_public_key,
           wrapped_content_key: wrapped_key,
           key_nonce: <nonce used for wrapping>
         }]
       }

     IF privacy_level == individual(recipient):
       shared_secret = x25519_DH(creator_secret, recipient_public)
       send_key = HKDF(shared_secret, "spheres-send-v1", creator_public)
       wrapped_key_recipient = XChaCha20Poly1305_encrypt(
         key = send_key,
         nonce = random(24),
         plaintext = content_key
       )
       // Also wrap for self (so creator can still view)
       device_key = HKDF(creator_secret, "spheres-device-v1", device_id)
       wrapped_key_self = XChaCha20Poly1305_encrypt(
         key = device_key,
         nonce = random(24),
         plaintext = content_key
       )
       envelope = {
         privacy: "individual",
         content_hash,
         nonce,
         mime_type,
         wrapped_keys: [
           {recipient: creator_public_key, wrapped_content_key: wrapped_key_self, ...},
           {recipient: recipient_public_key, wrapped_content_key: wrapped_key_recipient, ...}
         ]
       }

     IF privacy_level == group(group_id):
       wrapped_key_group = XChaCha20Poly1305_encrypt(
         key = group_key,
         nonce = random(24),
         plaintext = content_key
       )
       // Also wrap for self
       wrapped_key_self = ... (same as above)
       envelope = {
         privacy: "group",
         group_id,
         group_key_epoch,
         content_hash,
         nonce,
         mime_type,
         wrapped_keys: [
           {recipient: creator_public_key, wrapped_content_key: wrapped_key_self, ...},
           {recipient: "group:" + group_id, wrapped_content_key: wrapped_key_group, ...}
         ]
       }

  8. Sign the envelope:
     envelope_signature = Ed25519_sign(creator_secret, serialize(envelope))

  9. Store envelope + signature on DHT (as a record subkey or separate record)

  10. Return content_ref = {
        record_key: <DHT key of envelope>,
        content_hash,
        privacy: privacy_level
      }
```

### 4.2 Decrypting Content

```
Input:
  - content_ref: {record_key, content_hash, privacy}
  - reader_keypair: Ed25519 KeyPair
  - group_keys: Map<group_id, group_key> (if applicable)

Steps:

  1. Fetch envelope from DHT using record_key

  2. Verify envelope_signature using creator's public key
     IF invalid: REJECT (tampered content)

  3. IF privacy == public:
       Fetch plaintext from DHT, verify content signature, return
       DONE

  4. Find the wrapped_key entry for the reader:
     - Look for reader_public_key in wrapped_keys
     - OR look for "group:<group_id>" if reader is a group member

  5. Unwrap the content_key:

     IF privacy == self:
       device_key = HKDF(reader_secret, "spheres-device-v1", device_id)
       content_key = XChaCha20Poly1305_decrypt(
         key = device_key,
         nonce = entry.key_nonce,
         ciphertext = entry.wrapped_content_key
       )

     IF privacy == individual:
       shared_secret = x25519_DH(reader_secret, creator_public)
       recv_key = HKDF(shared_secret, "spheres-recv-v1", creator_public)
       // Note: recv_key on reader side == send_key on creator side
       content_key = XChaCha20Poly1305_decrypt(
         key = recv_key,
         nonce = entry.key_nonce,
         ciphertext = entry.wrapped_content_key
       )

     IF privacy == group:
       group_key = group_keys[group_id]
       IF group_key_epoch != envelope.group_key_epoch:
         REJECT (key rotation — need updated group key)
       content_key = XChaCha20Poly1305_decrypt(
         key = group_key,
         nonce = entry.key_nonce,
         ciphertext = entry.wrapped_content_key
       )

  6. Fetch encrypted_content from BlockStore using content_hash

  7. Verify: BLAKE3(encrypted_content) == content_hash
     IF mismatch: REJECT (corrupted content)

  8. Decrypt:
     content = XChaCha20Poly1305_decrypt(
       key = content_key,
       nonce = envelope.nonce,
       ciphertext = encrypted_content,
       aad = encode(mime_type, creator_public_key, privacy_level)
     )

  9. Render in secure in-memory widget
     - DO NOT write plaintext to disk
     - DO NOT allow export/download for non-public content
     - Set FLAG_SECURE (Android) / prevent screenshot (iOS)

  10. Zero content_key from memory after rendering
```

---

## 5. Group Key Management

### 5.1 Group Key Derivation

```
When a group is created:
  1. Creator generates group_seed = random(32 bytes)
  2. group_key = HKDF(group_seed, "spheres-group-v1", group_id)
  3. group_key_epoch = 1
  4. For each initial member:
     - pairwise_secret = x25519_DH(creator_secret, member_public)
     - wrapped_group_seed = XChaCha20Poly1305_encrypt(
         key = HKDF(pairwise_secret, "spheres-group-seed-v1"),
         nonce = random(24),
         plaintext = group_seed
       )
     - Store wrapped_group_seed in group DHT record (member's subkey)
```

### 5.2 Adding a Member

```
  1. Existing admin generates new_group_seed = random(32 bytes)
  2. new_group_key = HKDF(new_group_seed, "spheres-group-v1", group_id)
  3. group_key_epoch += 1
  4. Re-wrap new_group_seed for ALL members (including new member)
  5. Store updated wrapped seeds in group DHT record
  6. New content uses new_group_key
  7. Old content remains encrypted with old key (existing members can still read it;
     new member cannot read content from before they joined)
```

### 5.3 Removing a Member

```
  1. Admin generates new_group_seed = random(32 bytes)
  2. new_group_key = HKDF(new_group_seed, "spheres-group-v1", group_id)
  3. group_key_epoch += 1
  4. Re-wrap new_group_seed for remaining members ONLY (excluding removed member)
  5. Store updated wrapped seeds
  6. Removed member retains old_group_key (can still decrypt content they already had)
  7. But cannot decrypt any new content (doesn't have new_group_seed)
```

---

## 6. No-Forward Enforcement

### 6.1 App-Level Controls

Since true cryptographic no-forward is impossible (a user can always photograph their screen), Spheres implements **strong app-level enforcement**:

1. **No download button** for `self`, `individual`, or `group` content
2. **No share/forward option** for restricted content
3. **Secure rendering widget**:
   - Android: `FLAG_SECURE` on the window prevents screenshots and screen recording
   - iOS: `UITextField.isSecureTextEntry` trick + `UIScreen.isCaptured` detection
4. **In-memory only decryption**: decrypted bytes are held in a `Uint8List` that is zeroed after the widget disposes; never written to app storage, cache, or temp files
5. **Clipboard blocking**: copy/paste is disabled for restricted text content
6. **No thumbnail generation** for restricted media in the file system

### 6.2 Content Forwarding Prevention

When a user tries to share restricted content:
- The app shows an error: "This content is private and cannot be shared"
- The recipient's public key is checked against the envelope's `wrapped_keys` list
- If the intended recipient is not in the list, the operation is blocked at the app layer

### 6.3 Watermarking (Future)

For high-sensitivity content, invisible watermarking can embed the viewer's public key into rendered images. If a screenshot leaks, the watermark identifies who captured it.

---

## 7. Storage Model

```
BlockStore (encrypted blobs):
  ├── content_hash_1 → encrypted_photo_bytes
  ├── content_hash_2 → encrypted_video_bytes
  └── content_hash_N → encrypted_content_bytes

DHT Records (access control envelopes):
  ├── content_record_1 → {
  │     privacy: "individual",
  │     content_hash: "...",
  │     nonce: "...",
  │     mime_type: "image/jpeg",
  │     wrapped_keys: [...],
  │     signature: "..."
  │   }
  └── group_record_1 → {
        subkey 0: group metadata
        subkey 1: member list + wrapped_group_seeds
        subkeys 2+: content envelopes
      }

ProtectedStore (local secrets):
  ├── identity_secret → Ed25519 secret key
  ├── device_key → derived from identity for self-encryption
  └── group_seeds → {group_id: current_seed, epoch}

TableStore (local indexes):
  ├── content_index → list of content_refs with metadata
  ├── group_keys → cached derived group keys
  └── pairwise_cache → cached DH shared secrets
```

---

## 8. Privacy Setting UI Model

```dart
enum ContentPrivacy {
  /// Only the creator can see this content
  onlyMe,

  /// Shared with a single specific person
  individual,

  /// Shared with members of a specific group
  group,

  /// Anyone can see this content (no encryption)
  public,
}

class PrivacySetting {
  final ContentPrivacy level;
  final String? recipientPublicKey;  // for individual
  final String? groupId;             // for group

  // Display helpers
  String get label => switch (level) {
    ContentPrivacy.onlyMe => 'Only Me',
    ContentPrivacy.individual => 'Specific Person',
    ContentPrivacy.group => 'Group',
    ContentPrivacy.public => 'Public',
  };

  IconData get icon => switch (level) {
    ContentPrivacy.onlyMe => Icons.lock,
    ContentPrivacy.individual => Icons.person,
    ContentPrivacy.group => Icons.group,
    ContentPrivacy.public => Icons.public,
  };
}
```

---

## 9. Wire Format

### Content Envelope (JSON, stored on DHT)

```json
{
  "version": 1,
  "creator": "<base64 public key>",
  "privacy": "individual",
  "content_hash": "<BLAKE3 hex>",
  "content_nonce": "<base64 24-byte nonce>",
  "mime_type": "image/jpeg",
  "content_size": 245760,
  "created_at": 1711440000,
  "wrapped_keys": [
    {
      "recipient": "<base64 public key>",
      "wrapped_content_key": "<base64 encrypted key>",
      "key_nonce": "<base64 24-byte nonce>",
      "method": "x25519-xchacha20"
    },
    {
      "recipient": "group:abc123",
      "wrapped_content_key": "<base64 encrypted key>",
      "key_nonce": "<base64 24-byte nonce>",
      "method": "group-xchacha20",
      "epoch": 3
    }
  ],
  "signature": "<base64 Ed25519 signature over all fields except signature>"
}
```

---

## 10. Threat Model

### What this protocol protects against:

| Threat | Protection |
|--------|-----------|
| Server reading your data | No servers — P2P via Veilid DHT |
| Network observer reading content | All content encrypted before DHT write |
| DHT node reading stored data | Only encrypted blobs stored on DHT |
| Unauthorized person accessing content | Content key only wrapped for authorized recipients |
| Removed group member reading new content | Group key rotation on membership change |
| Content forwarding by recipient | App-level enforcement (no download/share for restricted) |
| Device theft | Identity secret in ProtectedStore (OS keychain / encrypted vault) |
| Key compromise | Per-content unique keys limit blast radius |

### What this protocol does NOT protect against:

| Threat | Reason |
|--------|--------|
| Screenshots / screen photography | Physical access to screen; mitigated by FLAG_SECURE |
| Malicious app modifications | User can build a modified client; mitigated by signature verification |
| Compromised device OS | If the OS is compromised, all bets are off |
| Quantum computing (future) | Current primitives are not post-quantum; lattice-based upgrade path planned |

---

## 11. Future: Post-Quantum Upgrade Path

The protocol name references "lattice-based" to signal the intended upgrade path:

1. **Phase 1 (current):** x25519 + XChaCha20-Poly1305 (fast, proven, available in Veilid)
2. **Phase 2 (future):** Hybrid key exchange — x25519 + CRYSTALS-Kyber (lattice-based KEM)
   - Both classical and post-quantum key exchange run in parallel
   - Content key is derived from BOTH shared secrets: `content_key = HKDF(x25519_secret || kyber_secret)`
   - If either algorithm is broken, the other still protects
3. **Phase 3 (long-term):** Full transition to lattice-based primitives when standardized and battle-tested

This hybrid approach follows NIST's recommendation for post-quantum migration.
