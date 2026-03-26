# Sphere Protocol Specification

## Identity

### Keypair Generation

Each Sphere user is identified by a single Ed25519 keypair generated via Veilid's crypto system (`crypto.best().generate_keypair()`). The keypair consists of:

- **Public key** (32 bytes) -- the user's globally unique identifier on the Veilid network
- **Secret key** (32 bytes) -- used to sign DHT records and decrypt private messages

### Storage

The keypair is stored in Veilid's ProtectedStore:

| Key | Value | Format |
|-----|-------|--------|
| `identity_secret` | Secret key | Base64-encoded 32 bytes |
| `identity_public` | Public key | Base64-encoded 32 bytes |

The ProtectedStore uses the OS keychain (iOS Keychain, Android Keystore) where available and falls back to Veilid's encrypted file-based vault.

### Identity Format

For sharing and backup, identities are encoded as base64 strings:

**Full keypair (backup/export):**
```
[4 bytes: CryptoKind tag][32 bytes: public key][32 bytes: secret key]
```
Total: 68 bytes, base64-encoded.

**Public key only (sharing with contacts):**
```
[4 bytes: CryptoKind tag][32 bytes: public key]
```
Total: 36 bytes, base64-encoded.

The CryptoKind tag identifies the cryptographic suite (currently Veilid's best available, which uses Ed25519/x25519/XChaCha20-Poly1305).

### Exchange

Users share their public key string out-of-band: QR code, copy-paste, NFC, or any other channel. The public key string is sufficient to look up the user's profile on the DHT and initiate encrypted communication.

## DHT Record Schemas

All DHT records use Veilid's `DHTSchema::dflt()` constructor, which creates records with a default owner and a specified number of subkeys.

### Profile Schema (3 subkeys)

Created by `schema::profile_schema()`.

| Subkey | Index | Content | Writer |
|--------|-------|---------|--------|
| Info | 0 | Display name, bio, metadata | Owner only |
| Avatar | 1 | BlockStore hash reference for avatar image | Owner only |
| Status | 2 | Online/offline/away status flag | Owner only |

**Info subkey value (JSON):**
```json
{
  "display_name": "Alice",
  "bio": "Privacy advocate",
  "post_list_dht_key": "<base64-encoded DHT record key>",
  "created_at": "2026-03-19T12:00:00Z"
}
```

**Avatar subkey value (JSON):**
```json
{
  "block_hash": "<BLAKE3 hash of avatar image>",
  "mime_type": "image/png",
  "size_bytes": 45230
}
```

**Status subkey value (JSON):**
```json
{
  "status": "online",
  "last_seen": "2026-03-19T12:34:56Z"
}
```

### Conversation Schema (multi-writer)

Created by `schema::conversation_schema(member_count)`.

Total subkeys: `member_count * 256`. Each member is assigned a contiguous block of 256 subkeys for writing their messages, providing ample scrollback history without requiring record rotation.

| Subkey Range | Content | Writer |
|-------------|---------|--------|
| `member_0 * 256` to `member_0 * 256 + 255` | Member 0's messages | Member 0 |
| `member_1 * 256` to `member_1 * 256 + 255` | Member 1's messages | Member 1 |
| ... | ... | ... |

The first subkey in each member's range (offset 0) stores metadata about the member's latest message counter, enabling efficient polling.

For a two-person direct conversation, the schema has `2 * 256 = 512` subkeys. Both parties are added as writers to the DHT record.

### Post Schema (2 subkeys)

Created by `schema::post_schema()`.

| Subkey | Index | Content | Writer |
|--------|-------|---------|--------|
| Content | 0 | Post text, media references, timestamp | Owner only |
| Reactions | 1 | List of reactions from contacts | Multiple writers (contacts) |

**Content subkey value (JSON):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "author": "<base64 public key>",
  "text": "Post content here",
  "media_refs": [
    {
      "block_hash": "<BLAKE3 hash>",
      "mime_type": "image/jpeg",
      "size_bytes": 1024000
    }
  ],
  "timestamp": "2026-03-19T12:00:00Z",
  "signature": "<base64 Ed25519 signature>"
}
```

**Reactions subkey value (JSON):**
```json
{
  "reactions": [
    {
      "sender": "<base64 public key>",
      "type": "like",
      "timestamp": "2026-03-19T12:05:00Z",
      "signature": "<base64 Ed25519 signature>"
    }
  ]
}
```

### Group Schema

Created by `schema::group_schema(max_members)`.

Total subkeys: `max_members + 2`. Subkey 0 is group metadata, subkey 1 is the member list, and subkeys 2 through `max_members + 1` are assigned one per member for writing messages.

| Subkey | Index | Content | Writer |
|--------|-------|---------|--------|
| Meta | 0 | Group name, description, creator | Group creator (owner) |
| Members | 1 | Ordered list of member public keys | Group creator (owner) |
| Messages | 2 to `max_members + 1` | One subkey per member for their messages | Respective member |

**Meta subkey value (JSON):**
```json
{
  "name": "Privacy Research Group",
  "description": "Discussing decentralized alternatives",
  "creator": "<base64 public key>",
  "created_at": "2026-03-19T12:00:00Z",
  "max_members": 50
}
```

**Members subkey value (JSON):**
```json
{
  "members": [
    {
      "public_key": "<base64 public key>",
      "display_name": "Alice",
      "subkey_index": 2,
      "joined_at": "2026-03-19T12:00:00Z"
    },
    {
      "public_key": "<base64 public key>",
      "display_name": "Bob",
      "subkey_index": 3,
      "joined_at": "2026-03-19T12:01:00Z"
    }
  ]
}
```

## Message Format

All messages (direct and group) use the following JSON structure:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "sender": "<base64 public key of sender>",
  "recipient": "<base64 public key of recipient, or group DHT key>",
  "content": {
    "type": "text",
    "body": "Hello, this is a message",
    "media_refs": [],
    "reply_to": null
  },
  "timestamp": "2026-03-19T12:00:00Z",
  "signature": "<base64 Ed25519 signature over all fields except signature>"
}
```

### Content Types

| Type | Fields | Description |
|------|--------|-------------|
| `text` | `body` (string) | Plain text message |
| `media` | `body` (optional caption), `media_refs` (array) | Message with attached media |
| `reply` | `body` (string), `reply_to` (message UUID) | Reply to a previous message |
| `system` | `body` (string) | System-generated message (member joined, left, etc.) |

### Signature Computation

The signature is computed over a canonical JSON serialization of all message fields excluding the `signature` field itself. The signing process:

1. Construct the message object without the `signature` field.
2. Serialize to canonical JSON (sorted keys, no extra whitespace).
3. Sign the resulting byte string with the sender's Ed25519 secret key.
4. Base64-encode the 64-byte signature and attach it to the message.

Verification: the recipient reconstructs the canonical JSON (excluding `signature`), retrieves the sender's public key, and verifies the Ed25519 signature.

## Contact Exchange Protocol

Adding a contact is a mutual, out-of-band process. Neither party needs to trust a server.

### Exchange Payload

```json
{
  "version": 1,
  "public_key": "<base64 public key string>",
  "profile_dht_key": "<Veilid DHT record key for profile>",
  "timestamp": "2026-03-19T12:00:00Z"
}
```

This payload is encoded as a base64 string or rendered as a QR code.

### Protocol Steps

1. **User A** generates their contact-exchange payload and shares it with User B via an out-of-band channel (QR code scan, copy-paste, NFC tap, etc.).
2. **User B** decodes the payload, opens User A's profile DHT record to verify the identity, and stores User A in their local contact list (TableStore).
3. **User B** generates their own contact-exchange payload and sends it back to User A via the same or a different out-of-band channel.
4. **User A** decodes, verifies, and stores User B.
5. Either party can now create a conversation DHT record with both users as writers, initiating encrypted messaging.

### Why Out-of-Band?

The exchange is deliberately out-of-band to avoid any server-mediated discovery. There is no username search, no phone number lookup, no "people you may know" feature. You add only people you already have a channel to communicate with. This eliminates the metadata that centralized platforms harvest from contact graphs.

## Group Management Protocol

### Group Creation

1. Creator generates a group DHT record using `group_schema(max_members)`.
2. Creator writes group metadata to subkey 0 (name, description, max_members).
3. Creator adds themselves to the member list at subkey 1 with `subkey_index: 2`.
4. Creator is the DHT record owner and controls the member list.

### Invite

1. Creator generates a group-invite payload:
   ```json
   {
     "version": 1,
     "group_dht_key": "<DHT record key>",
     "group_name": "Privacy Research Group",
     "inviter": "<base64 public key>",
     "timestamp": "2026-03-19T12:00:00Z"
   }
   ```
2. Payload is shared out-of-band (same as contact exchange).

### Join

1. Invitee decodes the invite payload.
2. Invitee reads the group metadata (subkey 0) and member list (subkey 1) to verify the group.
3. Invitee sends a join request to the creator (via their existing direct conversation or a new one).
4. Creator adds the invitee to the member list (subkey 1) and assigns them a message subkey.
5. Creator adds the invitee as a DHT record writer for their assigned subkey.
6. Invitee can now write messages to their assigned subkey.

### Leave

1. Member notifies the group (writes a system message to their subkey).
2. Creator removes the member from the member list (subkey 1).
3. Creator revokes the member's writer access to the DHT record.

## Feed Publishing Protocol

### Publishing a Post

1. Author creates a new post DHT record using `post_schema()`.
2. Author writes post content to subkey 0 (text, media references, signature).
3. Author updates their local post list (stored in their profile's `post_list_dht_key` or in a separate feed-index DHT record).

### Discovering Posts

Contacts discover new posts by periodically polling the profile or feed-index records of their contacts:

1. For each contact in the local contact list, read their profile DHT record.
2. Check the `post_list_dht_key` for new post record keys since the last poll.
3. For each new post key, open the post DHT record and read subkey 0.
4. Display in the local feed, ordered by timestamp.

There is no global feed, no algorithmic ranking, and no recommendation engine. You see posts only from people you have explicitly added as contacts.

### Reacting to a Post

1. Reader constructs a reaction object with their public key, reaction type, timestamp, and signature.
2. Reader appends their reaction to the post's reactions subkey (subkey 1).
3. The post owner (and other readers) see the updated reactions on next read.

## Media References

Media (photos, videos, voice messages, file attachments) is stored in Veilid's BlockStore as content-addressed blobs. Messages and posts reference media by block hash rather than embedding the binary data in DHT records.

### Media Reference Format

```json
{
  "block_hash": "<BLAKE3 hash of the media content>",
  "mime_type": "image/jpeg",
  "size_bytes": 1024000,
  "thumbnail_hash": "<BLAKE3 hash of thumbnail, optional>",
  "encryption_key": "<base64 XChaCha20-Poly1305 key used to encrypt the block>"
}
```

### Flow

1. Sender captures or selects media on-device.
2. Media is compressed/resized locally.
3. Media is encrypted with a random XChaCha20-Poly1305 key.
4. Encrypted blob is stored in the local BlockStore, yielding a BLAKE3 hash.
5. The media reference (hash + encryption key) is included in the message or post.
6. Recipient receives the message, extracts the media reference, fetches the block by hash, decrypts with the included key, and displays.

The encryption key is transmitted inside the already-encrypted message or post, so it is never visible to the network.

## Wire Format

All data stored in DHT subkeys and exchanged between components is serialized as **JSON**. The `schema.rs` module provides `serialize()` (via `serde_json::to_vec`) and `deserialize()` (via `serde_json::from_slice`) helpers.

### Current: JSON

- Human-readable, easy to debug during development.
- Well-supported by both Rust (`serde_json`) and Dart (`dart:convert`).
- Moderate overhead for binary-heavy fields (base64 encoding).

### Future: Protocol Buffers

The Rust crate includes `prost` and `prost-build` dependencies, indicating a planned migration to Protocol Buffers for:

- Smaller wire size (especially for binary keys and signatures).
- Stricter schema enforcement.
- Better forward/backward compatibility with versioned field numbers.

The migration would replace JSON serialization for DHT values and message formats while keeping the logical schema (subkey layout, field semantics) identical.
