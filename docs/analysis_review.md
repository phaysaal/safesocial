# Spheres: Architectural & Security Review

This document outlines the current weaknesses, security gaps, and missing features identified in the Spheres (SafeSocial) project. It serves as a roadmap for hardening the platform's privacy guarantees and improving its technical robustness.

---

## 1. Architectural Weaknesses

### A. Relay Room ID Metadata Leak
**Location:** `safesocial_app/lib/services/relay_service.dart` (`_computeRoomId`)

*   **The Flaw:** The room ID is a deterministic hash of two participants' public keys. 
*   **The Risk:** An observer (e.g., Cloudflare, ISP, or a malicious actor with a list of target public keys) can pre-calculate these hashes and monitor exactly who is communicating with whom, even if they cannot decrypt the message content.
*   **The Fix:** Implement a keyed hash (HMAC) or derive a temporary room identifier using an Elliptic Curve Diffie-Hellman (ECDH) shared secret known only to the two peers.

### B. Protocol Divergence (Dart vs. Rust)
**Location:** `safesocial_app/lib/services/` vs. `safesocial_core/src/`

*   **The Flaw:** The Flutter app implements its social protocol (SMPL schemas, relay fallback logic) in Dart, while the Rust core maintains a separate, non-identical set of schema definitions.
*   **The Risk:** This "split-brain" architecture makes it difficult to maintain consistency, increases the bug surface area, and prevents the creation of non-Flutter clients (CLI, desktop, etc.).
*   **The Fix:** Centralize all social protocol logic (DHT schema creation, message serialization, encryption/signing) in the `safesocial_core` Rust library. The Flutter app should act as a "thin client" that calls these methods via FFI.

### C. Polling-Based Feed Inefficiency
**Location:** `safesocial_app/lib/services/feed_service.dart`

*   **The Flaw:** The current strategy relies on periodically polling contacts' DHT records for new posts.
*   **The Risk:** Battery drain and high network overhead as the contact list grows. Every "sync" cycle triggers $O(N)$ DHT reads.
*   **The Fix:** Switch to **Veilid Watches**. The app should subscribe to the DHT records of all contacts; the Veilid network will then push updates to the device only when new content is published.

---

## 2. Security & Privacy Gaps

### A. Lack of Forward Secrecy
**Location:** `safesocial_app/lib/services/chat_service.dart` & `crypto_service.dart`

*   **The Flaw:** Messages are encrypted using a static shared secret derived from long-term identity keys.
*   **The Risk:** If a user's device is compromised and their identity secret key is extracted, an attacker can decrypt **the entire history** of that user's messages.
*   **The Fix:** Implement the **Double Ratchet Algorithm** (Signal Protocol) to ensure that every message uses a unique, ephemeral key.

### B. Media Metadata Leakage
**Location:** `safesocial_app/lib/services/media_service.dart`

*   **The Flaw:** Photos and videos are uploaded to the BlockStore without explicit metadata stripping.
*   **The Risk:** Images often contain EXIF data (GPS coordinates, timestamps, device IDs) that can deanonymize a user even if their identity is hidden by Veilid.
*   **The Fix:** Integrate a "Privacy Scrubbing" step that strips all non-essential binary metadata from media before it is hashed or uploaded.

---

## 3. Missing Features (Roadmap)

### A. Multi-Device Synchronization
*   **The Goal:** Allow a user to use the same identity on multiple devices (e.g., phone and tablet).
*   **The Challenge:** Syncing a local-first `TableStore` without a central server.
*   **The Feature:** A "Device Linking" protocol where a secondary device is authorized via QR code to clone the identity and sync message history over a local P2P link.

### B. "Stealth" Contact Discovery
*   **The Goal:** Find friends who are already on the platform without a global directory.
*   **The Feature:** Use Private Information Retrieval (PIR) or hashed phone number matching to signal presence to existing contacts without revealing the social graph to the network.

### C. Decentralized Content Moderation
*   **The Goal:** Filter spam or harmful content without a central moderator.
*   **The Feature:** A **Web of Trust (WoT)** system. Users can "mute" or "flag" public keys, and these signals propagate through their social graph to help others automatically filter their feeds.

### D. Social Identity Recovery
*   **The Goal:** Recover an identity if a device is lost.
*   **The Feature:** **Shamir's Secret Sharing.** Split the identity recovery key into $N$ parts and distribute them to $N$ trusted contacts. If the user loses their device, $M$ of those contacts (e.g., 3 out of 5) can collaborate to help the user regenerate their identity.

---

## 4. Priority Actions Summary

1.  **Immediate:** Transition from deterministic Relay Room IDs to ECDH-derived identifiers to eliminate metadata leakage.
2.  **Structural:** Unify the social protocol by moving the Dart-based schema/messaging logic into the Rust `safesocial_core`.
3.  **Security:** Implement a Double Ratchet mechanism for messaging to provide Forward Secrecy.
4.  **UX/Stability:** Replace polling in `FeedService` with Veilid Watches for better performance and battery life.
