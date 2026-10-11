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

/// Raised when an envelope comes from a device we have not been told about.
///
/// The identity signature already proves who sent it; what is missing is the
/// device key to derive a session with. The caller should refresh the sender's
/// device list and try the envelope again, not drop it.
class UnknownDeviceException implements Exception {
  final String peerKey;
  final String deviceKey;
  const UnknownDeviceException(this.peerKey, this.deviceKey);
  @override
  String toString() =>
      'UnknownDeviceException: $peerKey sent from an unlisted device';
}

/// One envelope, sealed for one device.
class SealedForDevice {
  final String peerIdentityKey;

  /// X25519 public key of the device it is sealed for, hex.
  final String deviceKey;
  final String sealed;

  const SealedForDevice({
    required this.peerIdentityKey,
    required this.deviceKey,
    required this.sealed,
  });
}

/// Owns the [PairwiseSession] for each (contact, device), and their
/// persistence.
///
/// Sessions are derived, not negotiated: given our X25519 device key pair and
/// a device's X25519 public key, both sides independently arrive at the same
/// state. Losing this store therefore costs message ordering, not the ability
/// to communicate — a fresh session decrypts new messages fine.
///
/// A person may have several devices, each with its own X25519 key. There is
/// one session per pair of devices, so no two devices ever advance the same
/// chain — which is what made running two devices at once corrupt
/// conversations. Sealing to a person means sealing once per device they have,
/// and once per other device *we* have, so our own devices see what we sent.
///
/// Persistence note: ratchet state is stored through SecureStore, so it is
/// encrypted at rest. Forward secrecy therefore holds against someone who
/// reads the device's storage as well as someone watching the network — though
/// not against a live compromised process, which can ask the keystore for the
/// key exactly as the app does.
class SessionManager {
  static const _prefsKey = 'spheres_sessions_v1';

  /// Keyed by `<peer identity>|<peer device key>`.
  final Map<String, PairwiseSession> _sessions = {};

  SimpleKeyPair? _myKeyExchangeKeyPair;
  String? _myDeviceKey;
  String? _myIdentityKey;
  String? _myIdentitySecret;

  /// Every X25519 device key an identity currently uses, our own included.
  /// Supplied by the app from the contact list and the identity's device
  /// list. When null, or when it returns nothing, the single key handed to
  /// [sessionFor] is the only device.
  List<String> Function(String identityKey)? deviceResolver;

  /// Seen envelope IDs, for replay rejection in wrap mode (chain mode is
  /// covered by the ratchet index). Bounded so a peer cannot grow it forever.
  final Set<String> _seenEnvelopeIds = {};
  static const int _maxSeenIds = 4096;

  bool get isReady =>
      _myKeyExchangeKeyPair != null &&
      _myIdentityKey != null &&
      _myIdentitySecret != null;

  String? get myIdentityKey => _myIdentityKey;

  /// Our own device's X25519 public key, hex. Known once configured.
  String? get myDeviceKey => _myDeviceKey;

  Future<void> configure({
    required SimpleKeyPair keyExchangeKeyPair,
    required String identityKey,
    required String identitySecret,
  }) async {
    _myKeyExchangeKeyPair = keyExchangeKeyPair;
    _myIdentityKey = identityKey;
    _myIdentitySecret = identitySecret;
    _myDeviceKey = hex.encode((await keyExchangeKeyPair.extractPublicKey()).bytes);
    _dropSessionsOfOtherKeys();
  }

  /// Forget every session that was derived from an exchange key other than
  /// the one we hold now.
  ///
  /// A session's root is the Diffie-Hellman of our key and theirs; when our
  /// key changes (a device re-linked, an identity restored, a key
  /// regenerated) every stored session is for a key we no longer have. Kept,
  /// they were handed out by [sessionFor] and derived mailbox addresses the
  /// other side did not share: a re-linked phone listened on channels nobody
  /// wrote to and never saw why. Sessions saved without a device key predate
  /// devices and go the same way; all of them re-derive on first use.
  void _dropSessionsOfOtherKeys() {
    final mine = _myDeviceKey;
    if (mine == null) return;
    _sessions.removeWhere((_, s) => s.myDeviceKey != mine);
  }

  static String _key(String peer, String device) => '$peer|$device';

  /// Every device key we would seal to for [identityKey].
  ///
  /// For our own identity that is every device except this one; for anyone
  /// else, every device they have published, or [fallback] when we only know
  /// one key.
  List<String> devicesOf(String identityKey, {String? fallback}) {
    final resolved = deviceResolver?.call(identityKey) ?? const [];
    var keys = resolved.isNotEmpty
        ? List<String>.from(resolved)
        : (fallback == null ? <String>[] : [fallback]);
    if (identityKey == _myIdentityKey) {
      keys = keys.where((k) => k != _myDeviceKey).toList();
    }
    return keys;
  }

  /// Get or derive the session for one device of a contact.
  ///
  /// [peerKeyExchangePublicKey] is that device's X25519 public key, hex. For
  /// a contact with one device this is the key they published, exactly as
  /// before devices existed.
  Future<PairwiseSession> sessionFor({
    required String peerIdentityKey,
    required String? peerKeyExchangePublicKey,
  }) async {
    if (peerKeyExchangePublicKey == null) {
      throw NoSessionException(peerIdentityKey);
    }
    final existing = _sessions[_key(peerIdentityKey, peerKeyExchangePublicKey)];
    if (existing != null) return existing;

    if (!isReady) throw NoSessionException(peerIdentityKey);

    final List<int> peerBytes;
    try {
      peerBytes = hex.decode(peerKeyExchangePublicKey);
    } catch (_) {
      throw NoSessionException(peerIdentityKey);
    }
    if (peerBytes.length != 32) throw NoSessionException(peerIdentityKey);

    final session = await PairwiseSession.establish(
      myKeyExchangeKeyPair: _myKeyExchangeKeyPair!,
      peerKeyExchangePublicKey: peerBytes,
      myIdentityKey: _myIdentityKey!,
      peerIdentityKey: peerIdentityKey,
    );
    _sessions[_key(peerIdentityKey, peerKeyExchangePublicKey)] = session;
    return session;
  }

  /// Derive the relay mailbox shared with one device of a contact for a given
  /// purpose.
  ///
  /// Distinct purposes ('chat', 'feed', 'call') give distinct addresses, so the
  /// relay cannot tell that two channels belong to the same pair of people.
  /// Distinct devices give distinct addresses too, for the same reason.
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

  /// Encrypt [plaintext] for one device of a contact.
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

  /// Encrypt [plaintext] once for every device of [peerIdentityKey].
  ///
  /// [fallbackExchangeKey] is the single key we hold for a contact who has
  /// not published a device list. [onlyDevice] restricts the fan-out to one
  /// device, e.g. the one that answered a call. Throws [NoSessionException]
  /// when there is nothing to seal to.
  Future<List<SealedForDevice>> sealForDevices({
    required String peerIdentityKey,
    required String? fallbackExchangeKey,
    required String type,
    required String plaintext,
    SealMode mode = SealMode.chain,
    String? onlyDevice,
  }) async {
    var devices = devicesOf(peerIdentityKey, fallback: fallbackExchangeKey);
    if (onlyDevice != null) devices = devices.where((d) => d == onlyDevice).toList();
    if (devices.isEmpty) throw NoSessionException(peerIdentityKey);

    final out = <SealedForDevice>[];
    for (final device in devices) {
      out.add(SealedForDevice(
        peerIdentityKey: peerIdentityKey,
        deviceKey: device,
        sealed: await seal(
          peerIdentityKey: peerIdentityKey,
          peerKeyExchangePublicKey: device,
          type: type,
          plaintext: plaintext,
          mode: mode,
        ),
      ));
    }
    return out;
  }

  /// Our other devices, as sealing targets. Empty when we have one device.
  Future<List<SealedForDevice>> sealForOwnDevices({
    required String type,
    required String plaintext,
    SealMode mode = SealMode.chain,
  }) async {
    final me = _myIdentityKey;
    if (me == null) return const [];
    final devices = devicesOf(me);
    if (devices.isEmpty) return const [];
    return sealForDevices(
      peerIdentityKey: me,
      fallbackExchangeKey: null,
      type: type,
      plaintext: plaintext,
      mode: mode,
    );
  }

  /// Verify and decrypt an inbound envelope.
  ///
  /// The session is looked up by the envelope's *signed* sender and device,
  /// not by the channel it arrived on, so a peer cannot impersonate someone
  /// else by writing into their room.
  ///
  /// [resolveExchangeKey] supplies a contact's X25519 public key by identity
  /// key; return null for unknown senders, whose messages are then rejected.
  /// A known sender writing from a device we have not been told about raises
  /// [UnknownDeviceException] so the caller can refresh their device list.
  Future<OpenedEnvelope> open({
    required String raw,
    required String? Function(String identityKey) resolveExchangeKey,
  }) async {
    final envelope = Envelope.decode(raw);

    if (_seenEnvelopeIds.contains(envelope.id)) {
      throw const EnvelopeException('Duplicate envelope id — replay');
    }

    final knownKey = resolveExchangeKey(envelope.from);
    final from = envelope.from;
    final String deviceKey;
    if (envelope.fromDevice.isEmpty) {
      // Sealed without a device key: the sender's only device.
      if (knownKey == null) throw NoSessionException(from);
      deviceKey = knownKey;
    } else {
      final known = <String>{
        if (knownKey != null) knownKey,
        ...(deviceResolver?.call(from) ?? const []),
        if (from == _myIdentityKey && _myDeviceKey != null) _myDeviceKey!,
      };
      if (known.isEmpty) throw NoSessionException(from);
      if (!known.contains(envelope.fromDevice)) {
        throw UnknownDeviceException(from, envelope.fromDevice);
      }
      deviceKey = envelope.fromDevice;
    }

    final session = await sessionFor(
      peerIdentityKey: from,
      peerKeyExchangePublicKey: deviceKey,
    );

    final plaintext = await envelope.open(session);

    if (_seenEnvelopeIds.length >= _maxSeenIds) {
      _seenEnvelopeIds.clear();
    }
    _seenEnvelopeIds.add(envelope.id);

    await persist();
    return OpenedEnvelope(
      from: envelope.from,
      fromDevice: deviceKey,
      type: envelope.type,
      timestampMs: envelope.timestampMs,
      plaintext: utf8.decode(plaintext),
    );
  }

  /// Drop every session with a peer, or with one device of theirs.
  void forget(String peerIdentityKey, {String? deviceKey}) {
    _sessions.removeWhere((key, _) => deviceKey == null
        ? key.startsWith('$peerIdentityKey|')
        : key == _key(peerIdentityKey, deviceKey));
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  /// The restart counter for a peer device, or 0 if we have no session with
  /// it.
  int resetEpochFor(String peerIdentityKey, {String? deviceKey}) {
    if (deviceKey != null) {
      return _sessions[_key(peerIdentityKey, deviceKey)]?.resetEpoch ?? 0;
    }
    var max = 0;
    _sessions.forEach((key, session) {
      if (key.startsWith('$peerIdentityKey|') && session.resetEpoch > max) {
        max = session.resetEpoch;
      }
    });
    return max;
  }

  /// Start a fresh pair of chains with a peer device, returning the new epoch.
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
      decoded.forEach((storedKey, json) {
        try {
          final session =
              PairwiseSession.fromJson(json as Map<String, dynamic>);
          // Sessions written before devices existed were keyed by identity
          // alone. Re-key them by the device they are actually with when that
          // is known; otherwise they are re-derived on next use.
          final key = storedKey.contains('|')
              ? storedKey
              : (session.peerDeviceKey.isNotEmpty
                  ? _key(session.peerIdentityKey, session.peerDeviceKey)
                  : null);
          if (key != null) _sessions[key] = session;
        } catch (_) {
          // A single unreadable session is dropped and re-derived on next use.
        }
      });
      _dropSessionsOfOtherKeys();
    } catch (_) {
      // Never wipe the whole store on a parse failure; leave it for inspection.
    }
  }
}

/// A verified, decrypted message.
class OpenedEnvelope {
  /// Ed25519 identity key of the sender, proven by signature.
  final String from;

  /// X25519 key of the sending device, as signed into the envelope.
  final String fromDevice;

  final String type;
  final int timestampMs;
  final String plaintext;

  const OpenedEnvelope({
    required this.from,
    required this.fromDevice,
    required this.type,
    required this.timestampMs,
    required this.plaintext,
  });
}
