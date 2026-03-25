# SafeSocial Threat Model

## Assets

The following assets require protection:

| Asset | Description | Sensitivity |
|-------|-------------|-------------|
| **User identity** | Ed25519 keypair (secret + public key) | Critical -- compromise means full impersonation |
| **Messages** | Direct and group chat content | High -- private communications |
| **Contacts** | List of known peers and their public keys | High -- reveals social graph |
| **Posts** | Feed content authored by the user | Medium -- intended for contacts but not public |
| **Media** | Photos, videos, voice messages, attachments | High -- may contain personal/sensitive content |
| **Metadata** | Timestamps, message counts, online status, group membership | Medium -- can reveal patterns even without content |

## Trust Model

| Entity | Trust Level | Rationale |
|--------|-------------|-----------|
| **Your device** | Trusted | All secrets live here. If the device is compromised, all bets are off. |
| **Veilid's cryptographic primitives** | Trusted | Ed25519, x25519, XChaCha20-Poly1305, BLAKE3 are well-studied algorithms. Veilid's implementations are open-source and auditable. |
| **Veilid network peers** | Untrusted | Any peer may be malicious, surveilling, or controlled by an adversary. |
| **The network (ISPs, governments)** | Untrusted | Network observers can see that Veilid traffic exists but should not be able to determine its content or endpoints. |
| **Your contacts** | Partially trusted | They can see content you share with them. They could screenshot, re-share, or be compromised. |

## Threats and Mitigations

### 1. Message Interception

**Threat:** An attacker intercepts messages in transit or reads them from DHT storage.

**Mitigation:** All message content is encrypted with XChaCha20-Poly1305 using a shared secret derived via x25519 Diffie-Hellman key exchange between the sender and recipient. DHT records contain only ciphertext. Without the shared secret, intercepted data is indistinguishable from random bytes.

**Residual risk:** If an attacker compromises one party's secret key, they can derive the shared secret and decrypt past and future messages (no forward secrecy in the current design -- see Future Improvements).

### 2. Metadata and Traffic Analysis

**Threat:** An observer monitors network traffic to determine who is communicating with whom, when, and how often.

**Mitigation:** All DHT operations go through Veilid private routes (onion routing). The routing context is created with `.with_privacy()`, which means:
- The sender's IP is hidden behind multiple relay hops.
- The recipient's IP is hidden behind their own private route.
- Intermediate nodes see only their immediate predecessor and successor.

**Residual risk:** A global passive adversary with visibility into a large fraction of Veilid nodes could theoretically perform timing correlation. This is the same limitation faced by Tor and similar onion routing networks.

### 3. Identity Theft

**Threat:** An attacker obtains the user's Ed25519 secret key and impersonates them.

**Mitigation:** The secret key is stored in Veilid's ProtectedStore, which uses:
- iOS Keychain on Apple devices
- Android Keystore on Android devices
- Encrypted file-based vault on desktop platforms

The key never leaves the ProtectedStore in plaintext during normal operation.

**Residual risk:** A rooted/jailbroken device or a device with malware capable of keychain extraction could compromise the key.

### 4. Message Tampering

**Threat:** An attacker modifies message content in transit or in DHT storage.

**Mitigation:** Every message includes an Ed25519 signature computed over the canonical JSON serialization of all message fields. Recipients verify the signature against the sender's known public key before displaying the message. Tampered messages fail verification and are rejected.

**Residual risk:** None for signed messages. Unsigned data (e.g., DHT record metadata managed by Veilid itself) relies on Veilid's built-in integrity mechanisms.

### 5. Unauthorized DHT Access

**Threat:** An attacker reads or writes to DHT records they should not have access to.

**Mitigation:** Veilid DHT records enforce access control:
- **Owner-only records** (profiles, posts): Only the keypair owner can write. Anyone can read (but content is encrypted or public by design).
- **Multi-writer records** (conversations, groups): Only explicitly added writers (identified by public key) can write to their assigned subkeys.

An attacker without the appropriate secret key cannot forge writes.

**Residual risk:** DHT records that are readable by anyone (by design, for profile discovery) expose the ciphertext. This is acceptable because the ciphertext reveals nothing without the decryption key.

### 6. Device Compromise

**Threat:** An attacker gains physical or remote access to the user's device.

**Mitigation:**
- ProtectedStore encrypts secrets using the OS keychain where available.
- TableStore data is encrypted at rest by Veilid.
- Device-level protections (PIN, biometrics, full-disk encryption) provide an additional layer.

**Residual risk:** A fully compromised device (root access, malware with keychain access) exposes all local data. This is a fundamental limitation of any local-first design. SafeSocial cannot protect data on a device that the user does not control.

### 7. Network-Level Surveillance

**Threat:** An ISP, government, or network operator monitors the user's internet traffic to identify SafeSocial usage and communication patterns.

**Mitigation:**
- Private routes hide the true source and destination of all DHT operations.
- No central servers exist that could be subpoenaed, monitored, or compelled to produce logs.
- Veilid traffic uses encrypted transports (TLS, WSS) that obscure content from passive observers.

**Residual risk:** An observer can determine that a device is participating in the Veilid network (by recognizing Veilid protocol traffic patterns or bootstrap node connections). They cannot determine what the user is doing within the network.

### 8. Sybil Attacks

**Threat:** An attacker creates many fake Veilid nodes to dominate DHT routing, enabling data interception or denial of service.

**Mitigation:** Veilid implements a peer reputation system that weights long-lived, well-behaving nodes more heavily than new or suspicious ones. DHT records are replicated across multiple peers, reducing the impact of any single malicious node.

**Residual risk:** A sufficiently resourced attacker could operate enough nodes to degrade DHT reliability. However, because all content is encrypted and signed, even a successful Sybil attack reveals no plaintext and cannot forge messages.

### 9. Denial of Service

**Threat:** An attacker makes the network or specific records unavailable.

**Mitigation:**
- **Local-first design:** All data is stored locally. The user can read their messages, contacts, and posts even when the network is completely unavailable.
- **DHT replication:** Records are replicated across multiple Veilid peers. Taking down a subset of peers does not destroy records.
- **Offline operation:** SafeSocial is designed to work offline. Messages composed offline are queued and delivered when connectivity is restored.

**Residual risk:** A sustained, large-scale attack on the Veilid network could delay message delivery. It cannot destroy data or prevent local access to already-synced content.

### 10. Key Loss

**Threat:** The user loses their device and with it their identity keypair, permanently losing access to their identity and encrypted data.

**Mitigation:** SafeSocial provides identity export/backup functionality (`identity_to_string()` / `identity_from_string()`). Users can export their full keypair as a base64 string and store it in a secure location (password manager, printed paper in a safe, etc.).

**Residual risk:** This is entirely the user's responsibility. If the user does not back up their identity and loses their device, the identity is unrecoverable. There is no "forgot password" flow -- this is by design.

## What SafeSocial Does NOT Protect Against

These threats are explicitly out of scope:

| Threat | Why It Is Out of Scope |
|--------|----------------------|
| **Compromised device (root/jailbreak)** | If an attacker has root access to the device, they can extract keys from the keychain, read decrypted messages from memory, and install keyloggers. No application-level protection can defend against this. |
| **Rubber-hose cryptanalysis** | If a user is physically coerced into unlocking their device or revealing their backup key, SafeSocial cannot help. This is a physical security problem, not a software problem. |
| **Screenshots by recipient** | Once a message is decrypted and displayed on a contact's screen, that contact can screenshot, photograph, or transcribe it. SafeSocial provides no DRM. |
| **Metadata within shared groups** | Group members can see each other's public keys, display names, message timestamps, and online status. This is inherent to the group functionality. A group member could share this information externally. |
| **Correlation via shared content** | If a user posts the same text or image on SafeSocial and a public platform, an observer could correlate the two identities. SafeSocial cannot prevent users from de-anonymizing themselves. |

## Comparison with Centralized Alternatives

The primary motivation for SafeSocial is protection against systemic, AI-powered surveillance platforms (Palantir-like systems) that aggregate data from social networks to model psychology, behavior, and predict future actions.

### What surveillance systems can extract from centralized social networks

| Data Category | Available on Centralized Platforms |
|---------------|-----------------------------------|
| Real identity | Full name, email, phone number, government ID (some platforms) |
| Social graph | Complete friend/follower list, interaction frequency, relationship strength |
| Communication content | Messages (often server-readable, even with "encryption" that holds server-side keys) |
| Behavioral metadata | Login times, session duration, click patterns, scroll behavior, typing indicators |
| Location | IP-based geolocation, GPS (if granted), location tags on posts/photos |
| Psychological profile | Likes, reactions, content engagement patterns, ad click behavior, search history |
| Content analysis | Posts, photos, videos analyzed by server-side ML for sentiment, topics, faces, objects |
| Device fingerprint | Browser/app telemetry, device model, OS version, installed apps |
| Cross-platform correlation | Shared identifiers (email, phone) link profiles across platforms |

### What surveillance systems can extract from SafeSocial

| Data Category | Available from SafeSocial |
|---------------|------------------------|
| Real identity | None. Identity is a cryptographic keypair with no link to real-world identity. |
| Social graph | None. Contact lists are local-only (TableStore). No server has a copy. |
| Communication content | None. Messages are E2E encrypted. No server holds plaintext or keys. |
| Behavioral metadata | None. No server to log sessions, clicks, or engagement. |
| Location | None. IP hidden by private routes. No GPS collection. |
| Psychological profile | None. No engagement tracking, no ad system, no recommendation algorithm. |
| Content analysis | None. Posts are encrypted and stored on user devices, not on servers. |
| Device fingerprint | None. No telemetry collection. |
| Cross-platform correlation | None. No email, phone, or username to correlate. |

**What remains observable:** A network observer can determine that a device is generating Veilid protocol traffic. They cannot determine what the user is doing, who they are communicating with, or what content is being exchanged. A surveillance system aggregating data from ISPs would see "this IP address uses Veilid" -- and nothing else.

## Future Improvements

| Improvement | Description | Impact |
|-------------|-------------|--------|
| **Key rotation** | Periodically generate new keypairs and migrate DHT records, limiting the window of compromise if a key is leaked. | Reduces damage from key compromise. |
| **Forward secrecy** | Implement a Double Ratchet protocol (or similar) for messaging, so that compromise of current keys does not decrypt past messages. | Eliminates retroactive decryption threat. |
| **Disappearing messages** | Messages that auto-delete after a configurable time, both locally and from DHT. | Reduces exposure window for sensitive conversations. |
| **Multi-device support** | Sync identity and data across multiple user-owned devices, with per-device sub-keys. | Improves usability without compromising the security model. |
| **Plausible deniability** | Explore deniable encryption schemes where the existence of hidden content cannot be proven. | Protects against coerced device inspection. |
| **Verified contacts** | Out-of-band verification ceremony (safety number comparison) to confirm contact authenticity. | Defends against man-in-the-middle during contact exchange. |
