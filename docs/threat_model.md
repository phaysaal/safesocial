# Spheres Threat Model

**Date:** 2026-07-30
**Applies to:** the system as actually built, verified by reading the source.

This replaces an earlier threat model that described a Veilid-based peer-to-peer
system. That system was never built. Everything below describes the relay-based
architecture that exists.

**Nothing here has been independently audited, and none of it has been exercised on
real devices.** Treat every claim as "designed and unit-tested", not "proven".

---

## 1. What the system is

- Identity is an Ed25519 keypair generated on the device, plus an X25519 subkey for
  key agreement. There is no account and no server-side record of a user.
- All content belongs to a **sphere**: a named set of members with a symmetric key
  that rotates on every membership change. There is no public audience anywhere in
  the data model.
- Everything transits one relay (a Cloudflare Worker), addressed by mailboxes derived
  from secrets only the participants share.
- Media is encrypted, chunked, and stored as blobs addressed by unguessable
  capabilities.

---

## 2. Adversaries, and what each one gets

### 2.1 The relay operator, or anyone who compels them

**Assumed hostile.** This is the adversary the architecture is shaped around.

Cannot:

- **Read content.** Everything is sealed with XChaCha20-Poly1305 before it is sent.
- **Identify participants.** A mailbox address is an Ed25519 public key derived from
  a shared secret, so it cannot be computed from public keys and traffic cannot be
  mapped onto a social graph. Chat, feed and call between one pair get distinct
  addresses, so those channels are not linkable to each other either.
- **Read anyone's mail.** Access requires signing a challenge with the mailbox key,
  verified against the address itself. There is no membership list to bypass, and a
  throwaway keypair proves nothing.
- **Forge or tamper.** Every envelope is signed by the sender's identity key, and the
  header is bound as AEAD associated data.

Can:

- **See timing** — when an address is active, and how often.
- **See approximate size.** Payloads are padded into buckets (512 B / 2 K / 8 K /
  32 K / 128 K), so the operator learns a size class rather than a length.
- **See longevity.** Addresses are secret-derived but *stable*, so it is observable
  that some pair has been communicating for months. Rotation is designed but not
  implemented: it needs a lookback window at least as long as the retention period,
  or mail queued to a retired mailbox is lost.
- **Withhold or delete.** A relay can drop messages. Delivery receipts make that
  visible to the sender, but do not prevent it.
- **See IP addresses**, via Cloudflare. The worker does not log them; Cloudflare's own
  logging is outside our control. Tor or a VPN is the only mitigation.

### 2.2 A network observer

Sees TLS to one hostname, learning that the app is in use and when. Content,
addresses and identities are inside TLS and encrypted again inside that.

### 2.3 A malicious contact or sphere member

Cannot:

- **Impersonate.** Authorship comes from a signature verified before display, and the
  payload's own author field is cross-checked against it; mismatches are dropped.
- **Read spheres they are not in.** Content is sealed to a sphere epoch key.
- **Read anything published after removal.** Removal bumps the epoch and mints a key
  they never receive. This is cryptographic, not a local flag.
- **Forge membership changes.** Operations are signed, must come from an admin, and an
  older epoch cannot be replayed over a newer one.
- **Add you to a sphere silently.** Invitations require explicit acceptance.

Can:

- **Keep what they already had.** Removal denies future content, not past content.
- **Screenshot, copy, or repost.** No DRM, and none is possible.
- **See who else is in a shared sphere** — membership is visible to members.
- **Correlate you across the spheres you share.**

### 2.4 Someone who has the device

**Currently the weakest area.**

- The Ed25519 identity key and the X25519 key are in the platform keystore
  (`flutter_secure_storage`).
- **Everything else is not.** Message history, sphere keys, ratchet state, contacts
  and posts are plaintext JSON in SharedPreferences. Anyone able to read the app's
  data directory — a rooted or jailbroken device, a forensic extraction, malware with
  the right permissions — reads all of it.
- Moving to SQLCipher is outstanding and is the highest-value hardening task left.
- Cloud backup is off (`allowBackup="false"`), so this does not leave via Android Auto
  Backup.

Forward secrecy limits the damage only partially. Direct messages advance a KDF chain
and drop used keys, so a device seized later cannot decrypt DMs it has already read
and discarded — but the plaintext history is still on disk, which makes that
protection largely theoretical today. Sphere content has no forward secrecy at all:
the epoch key opens everything published during that epoch.

### 2.5 A TURN operator

If a call cannot connect directly it is relayed, and the relay sees both parties' IP
addresses and the timing and volume of the media. The media itself stays
SRTP-protected. The default is a free public service, which the UI states; TURN can be
replaced or switched off entirely in settings.

### 2.6 Whoever ships the binary

Unaddressed. There are no reproducible builds, so a user cannot verify that an APK
matches this source. Release signing now fails rather than falling back to the public
Android debug key, but the keystore passphrase is weak and known to be.

---

## 3. What this does not protect against

| Threat | Why not |
|---|---|
| A compromised device | Local storage is unencrypted; see 2.4. |
| Traffic analysis | Timing and size class are visible; there is no cover traffic. |
| A malicious build | No reproducible builds. |
| Coercion | Nothing here survives someone being made to unlock their phone. |
| Screenshots by a member | Not solvable in software. |
| A relay refusing service | Availability is not a guarantee; the relay is replaceable, not redundant. |
| Correlation with other platforms | Posting the same content elsewhere links the identities. |

---

## 4. Cryptographic summary

| Purpose | Primitive |
|---|---|
| Identity, signatures | Ed25519 |
| Key agreement | X25519 |
| Content encryption | XChaCha20-Poly1305 |
| Key derivation | HKDF-SHA256, domain-separated per purpose |
| Passphrase vaults | Argon2id (19 MiB, t=2, p=1), then XChaCha20-Poly1305 |
| Direct-message forward secrecy | Symmetric KDF chain; keys deleted after use |
| Sphere content | Per-epoch random key, rotated on membership change |
| Social recovery | Shamir over GF(256), reconstruction verified against the identity key |

Notably **absent**: post-compromise security. There is no Diffie-Hellman ratchet, so
an attacker who obtains current DM chain state can follow the conversation forward.
This is why the app does not describe itself as implementing the Double Ratchet.

---

## 5. Known gaps, ranked

1. **Local storage is unencrypted.** Undermines several protections above.
2. **Never run.** Unit-tested, but no real message has crossed between two devices.
   Unknown unknowns dominate this list.
3. **Unaudited.** No independent review of the protocol or the implementation.
4. **Mailbox addresses do not rotate**, so long-lived pairs are observable as such.
5. **No post-compromise security** for direct messages.
6. **No forward secrecy** for sphere content.
7. **No reproducible builds.**
8. **Concurrent multi-device unsupported** — two devices sharing an identity would
   advance the same ratchet chains and reuse message keys. Linking is presented as
   moving devices, not running two.
9. **No push notifications**, deliberately: every practical provider learns that a
   given device received something, and when.

---

## 6. Before calling this a secure messenger

In order: encrypt local storage, run it on real devices, then commission an
independent review. Positioning it as a secure messenger before those three is not
defensible. If any claim in this document stops being true, update it — do not quietly
drop it.
