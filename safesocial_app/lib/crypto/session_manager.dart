import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import '../services/secure_store.dart';

import 'envelope.dart';
import 'mailbox.dart';
import 'pairwise_session.dart';

/// Raised when a contact cannot be messaged securely yet.
///
/// Callers must surface this rather than sending in the clear — silently
/// downgrading is exactly the failure mode this phase exists to remove.
class NoSessionException implements Exception {
  final String peerKey;
  const NoSessionException(this.peerKey);
  @override
  String toString() =>
      'NoSessionException: no key exchange key known for $peerKey';
}

/// Owns the [PairwiseSession] for each contact, and their persistence.
///
/// Sessions are derived, not negotiated: given our X25519 key pair and a
/// contact's X25519 public key, both sides independently arrive at the same
/// state. Losing this store therefore costs message ordering, not the ability
/// to communicate — a fresh session decrypts new messages fine.
///
/// Persistence note: ratchet state is stored through SecureStore, so it is
/// encrypted at rest. Forward secrecy therefore holds against someone who
/// reads the device's storage as well as someone watching the network — though
/// not against a live compromised process, which can ask the keystore for the
/// key exactly as the app does.
class SessionManager {
  static const _prefsKey = 'spheres_sessions_v1';

  final Map<String, PairwiseSession> _sessions = {};

  SimpleKeyPair? _myKeyExchangeKeyPair;
  String? _myIdentityKey;
  String? _myIdentitySecret;

  /// Seen envelope IDs, for replay rejection in wrap mode (chain mode is
  /// covered by the ratchet index). Bounded so a peer cannot grow it forever.
  final Set<String> _seenEnvelopeIds = {};
  static const int _maxSeenIds = 4096;

  bool get isReady =>
      _myKeyExchangeKeyPair != null &&
      _myIdentityKey != null &&
      _myIdentitySecret != null;

  String? get myIdentityKey => _myIdentityKey;

  void configure({
    required SimpleKeyPair keyExchangeKeyPair,
    required String identityKey,
    required String identitySecret,
  }) {
    _myKeyExchangeKeyPair = keyExchangeKeyPair;
    _myIdentityKey = identityKey;
    _myIdentitySecret = identitySecret;
  }

  /// Get or derive the session for a contact.
  ///
  /// [peerKeyExchangePublicKey] is the contact's X25519 public key, hex.
  Future<PairwiseSession> sessionFor({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
  }) async {
    final existing = _sessions[peerIdentityKey];
    if (existing != null) return existing;

    if (!isReady || peerKeyExchangePublicKey == null) {
      throw NoSessionException(peerIdentityKey);
    }

    final List<int> peerBytes;
    try {
      peerBytes = hex.decode(peerKeyExchangePublicKey);
    } catch (_) {
      throw NoSessionException(peerIdentityKey);
    }

    final session = await PairwiseSession.establish(
      myKeyExchangeKeyPair: _myKeyExchangeKeyPair!,
      peerKeyExchangePublicKey: peerBytes,
      myIdentityKey: _myIdentityKey!,
      peerIdentityKey: peerIdentityKey,
    );
    _sessions[peerIdentityKey] = session;
    return session;
  }

  /// Derive the relay mailbox shared with a contact for a given purpose.
  ///
  /// Distinct purposes ('chat', 'feed', 'call') give distinct addresses, so the
  /// relay cannot tell that two channels belong to the same pair of people.
  Future<Mailbox> mailboxFor({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
    required String purpose,
  }) async {
    final session = await sessionFor(
      peerIdentityKey: peerIdentityKey,
      peerKeyExchangePublicKey: peerKeyExchangePublicKey,
    );
    return Mailbox.fromSharedSecret(
      secret: await session.mailboxSecret(),
      purpose: purpose,
    );
  }

  /// Encrypt [plaintext] for a contact.
  ///
  /// Use [SealMode.chain] for conversational messages, which are ordered and
  /// benefit from forward secrecy, and [SealMode.wrap] for content that is
  /// fanned out or re-read (posts, album items, call signalling).
  Future<String> seal({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
    required String type,
    required String plaintext,
    SealMode mode = SealMode.chain,
  }) async {
    final session = await sessionFor(
      peerIdentityKey: peerIdentityKey,
      peerKeyExchangePublicKey: peerKeyExchangePublicKey,
    );

    final envelope = mode == SealMode.chain
        ? await Envelope.sealChain(
            session: session,
            type: type,
            plaintext: utf8.encode(plaintext),
            myIdentitySecretHex: _myIdentitySecret!,
          )
        : await Envelope.sealWrapped(
            session: session,
            type: type,
            plaintext: utf8.encode(plaintext),
            myIdentitySecretHex: _myIdentitySecret!,
          );

    await persist();
    return envelope.encode();
  }

  /// Verify and decrypt an inbound envelope.
  ///
  /// The session is looked up by the envelope's *signed* sender, not by the
  /// channel it arrived on, so a peer cannot impersonate someone else by
  /// writing into their room.
  ///
  /// [resolveExchangeKey] supplies a contact's X25519 public key by identity
  /// key; return null for unknown senders, whose messages are then rejected.
  Future<OpenedEnvelope> open({
    required String raw,
    required String? Function(String identityKey) resolveExchangeKey,
  }) async {
    final envelope = Envelope.decode(raw);

    if (_seenEnvelopeIds.contains(envelope.id)) {
      throw const EnvelopeException('Duplicate envelope id — replay');
    }

    final session = await sessionFor(
      peerIdentityKey: envelope.from,
      peerKeyExchangePublicKey: resolveExchangeKey(envelope.from),
    );

    final plaintext = await envelope.open(session);

    if (_seenEnvelopeIds.length >= _maxSeenIds) {
      _seenEnvelopeIds.clear();
    }
    _seenEnvelopeIds.add(envelope.id);

    await persist();
    return OpenedEnvelope(
      from: envelope.from,
      type: envelope.type,
      timestampMs: envelope.timestampMs,
      plaintext: utf8.decode(plaintext),
    );
  }

  void forget(String peerIdentityKey) {
    _sessions.remove(peerIdentityKey);
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// The restart counter for a peer, or 0 if we have no session with them.
  int resetEpochFor(String peerIdentityKey) =>
      _sessions[peerIdentityKey]?.resetEpoch ?? 0;

  /// Start a fresh pair of chains with a peer, returning the new epoch.
  ///
  /// Called when their messages have stopped authenticating, which means the
  /// two sides no longer agree on where the chains are. Nothing else recovers
  /// from that: the root is intact, but every message key derived from here on
  /// is wrong on one side or the other.
  Future<int> beginReset({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
  }) async {
    final session = await sessionFor(
      peerIdentityKey: peerIdentityKey,
      peerKeyExchangePublicKey: peerKeyExchangePublicKey,
    );
    await session.resetTo(session.resetEpoch + 1);
    await persist();
    return session.resetEpoch;
  }

  /// Adopt a restart the peer asked for.
  ///
  /// Returns true if this actually changed anything. A request for an epoch we
  /// are already at or past is ignored, so two sides that ask at the same
  /// moment converge on one answer instead of resetting each other in circles.
  Future<bool> adoptReset({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
    required int epoch,
  }) async {
    final session = await sessionFor(
      peerIdentityKey: peerIdentityKey,
      peerKeyExchangePublicKey: peerKeyExchangePublicKey,
    );
    final changed = await session.resetTo(epoch);
    if (changed) await persist();
    return changed;
  }

  Future<void> persist() async {
    final prefs = SecureStore.instance;
    await prefs.setString(
      _prefsKey,
      jsonEncode(_sessions.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  Future<void> load() async {
    final prefs = SecureStore.instance;
    final raw = await prefs.getString(_prefsKey);
    if (raw == null) return;

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((peer, json) {
        try {
          _sessions[peer] =
              PairwiseSession.fromJson(json as Map<String, dynamic>);
        } catch (_) {
          // A single unreadable session is dropped and re-derived on next use.
        }
      });
    } catch (_) {
      // Never wipe the whole store on a parse failure; leave it for inspection.
    }
  }
}

/// A verified, decrypted message.
class OpenedEnvelope {
  /// Ed25519 identity key of the sender, proven by signature.
  final String from;
  final String type;
  final int timestampMs;
  final String plaintext;

  const OpenedEnvelope({
    required this.from,
    required this.type,
    required this.timestampMs,
    required this.plaintext,
  });
}
