import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'pairwise_session.dart';
import 'spheres_crypto.dart';

/// Wire format version. Bump on any change to [Envelope._signedBytes] or the
/// field set, and reject unknown versions rather than guessing.
const int kEnvelopeVersion = 2;

/// How the payload key was established.
enum SealMode {
  /// Ratcheted chain key — forward secret, ordered, one recipient.
  chain,

  /// Random content key wrapped under the static pairwise wrapping key.
  /// Used where a ratchet cannot be kept in lockstep (feed, albums, groups).
  wrap,

  /// Content key wrapped under a sphere's per-epoch key, so every member can
  /// open it without the sender encrypting once per recipient.
  sphere,
}

/// Raised when an inbound envelope fails any integrity check.
///
/// Never catch this and fall back to reading the payload anyway — an envelope
/// that does not verify is attacker-controlled.
class EnvelopeException implements Exception {
  final String message;
  const EnvelopeException(this.message);
  @override
  String toString() => 'EnvelopeException: $message';
}

/// An authenticated, encrypted message on the wire.
///
/// Every envelope is signed by the sender's Ed25519 identity key and the
/// signature is verified before decryption is attempted. The signature covers
/// the full header, and the header is also passed as AEAD associated data, so
/// a relabelled or replayed-into-another-context envelope fails to open.
///
/// This closes the forgery holes in the previous wire format, where `author_id`
/// and `sender_id` were self-declared fields that nothing checked.
class Envelope {
  final int version;
  final SealMode mode;

  /// Application payload type: 'chat', 'post', 'reaction', 'call', ...
  final String type;

  /// Sender's Ed25519 identity public key, hex.
  final String from;

  /// Chain index. Meaningful in [SealMode.chain] only; -1 otherwise.
  final int sequence;

  /// Unique per envelope. Receivers must reject IDs they have already seen —
  /// this is what stops replay in [SealMode.wrap], which has no chain index.
  final String id;

  final int timestampMs;

  final Uint8List nonce;
  final Uint8List ciphertext;

  /// Wrapped content key and its nonce. Present in [SealMode.wrap] and
  /// [SealMode.sphere].
  final Uint8List? wrappedKey;
  final Uint8List? wrapNonce;

  /// Sphere this belongs to, and the epoch whose key opens it.
  /// Present in [SealMode.sphere] only.
  final String? sphereId;
  final int sphereEpoch;

  final Uint8List signature;

  const Envelope({
    required this.version,
    required this.mode,
    required this.type,
    required this.from,
    required this.sequence,
    required this.id,
    required this.timestampMs,
    required this.nonce,
    required this.ciphertext,
    required this.wrappedKey,
    required this.wrapNonce,
    required this.signature,
    this.sphereId,
    this.sphereEpoch = -1,
  });

  /// The exact bytes covered by the signature and used as AEAD associated data.
  ///
  /// Newline-delimited rather than JSON so it is unambiguous: no field can
  /// contain a newline (they are all integers, hex, base64, or a fixed-vocabulary
  /// type string), so no two distinct headers can produce the same bytes.
  static Uint8List _signedBytes({
    required int version,
    required SealMode mode,
    required String type,
    required String from,
    required int sequence,
    required String id,
    required int timestampMs,
    required Uint8List nonce,
    required Uint8List? wrappedKey,
    required Uint8List? wrapNonce,
    required String? sphereId,
    required int sphereEpoch,
  }) {
    final parts = [
      'spheres-envelope',
      '$version',
      mode.name,
      type,
      from,
      '$sequence',
      id,
      '$timestampMs',
      base64Encode(nonce),
      wrappedKey == null ? '' : base64Encode(wrappedKey),
      wrapNonce == null ? '' : base64Encode(wrapNonce),
      sphereId ?? '',
      '$sphereEpoch',
    ];
    return Uint8List.fromList(utf8.encode(parts.join('\n')));
  }

  Uint8List get associatedData => _signedBytes(
        version: version,
        mode: mode,
        type: type,
        from: from,
        sequence: sequence,
        id: id,
        timestampMs: timestampMs,
        nonce: nonce,
        wrappedKey: wrappedKey,
        wrapNonce: wrapNonce,
        sphereId: sphereId,
        sphereEpoch: sphereEpoch,
      );

  // ── Sealing ───────────────────────────────────────────────────────────────

  /// Seal [plaintext] to a contact using the ratcheted sending chain.
  ///
  /// Advances the chain, so calling this twice produces two distinct message
  /// keys — a key is never reused across messages.
  static Future<Envelope> sealChain({
    required PairwiseSession session,
    required String type,
    required List<int> plaintext,
    required String myIdentitySecretHex,
  }) async {
    final step = await session.sending.next();
    return _seal(
      mode: SealMode.chain,
      type: type,
      from: session.myIdentityKey,
      sequence: step.index,
      payloadKey: step.key,
      plaintext: plaintext,
      wrappedKey: null,
      wrapNonce: null,
      myIdentitySecretHex: myIdentitySecretHex,
    );
  }

  /// Seal [plaintext] under a fresh content key wrapped for the peer.
  ///
  /// No chain state changes, so this is safe for content that is fanned out or
  /// re-sent, at the cost of no forward secrecy (see
  /// [PairwiseSession.wrappingKey]).
  static Future<Envelope> sealWrapped({
    required PairwiseSession session,
    required String type,
    required List<int> plaintext,
    required String myIdentitySecretHex,
  }) async {
    final contentKey = SpheresCrypto.randomKey();
    final wrapNonce = SpheresCrypto.randomNonce();
    final wrapped = await SpheresCrypto.encrypt(
      key: await session.wrappingKey(),
      nonce: wrapNonce,
      plaintext: contentKey,
      aad: const <int>[],
    );

    return _seal(
      mode: SealMode.wrap,
      type: type,
      from: session.myIdentityKey,
      sequence: -1,
      payloadKey: contentKey,
      plaintext: plaintext,
      wrappedKey: wrapped,
      wrapNonce: wrapNonce,
      myIdentitySecretHex: myIdentitySecretHex,
    );
  }

  static Future<Envelope> _seal({
    required SealMode mode,
    required String type,
    required String from,
    required int sequence,
    required Uint8List payloadKey,
    required List<int> plaintext,
    required Uint8List? wrappedKey,
    required Uint8List? wrapNonce,
    required String myIdentitySecretHex,
    String? sphereId,
    int sphereEpoch = -1,
  }) async {
    final nonce = SpheresCrypto.randomNonce();
    final id = base64Encode(SpheresCrypto.randomBytes(16));
    final timestampMs = DateTime.now().millisecondsSinceEpoch;

    final aad = _signedBytes(
      version: kEnvelopeVersion,
      mode: mode,
      type: type,
      from: from,
      sequence: sequence,
      id: id,
      timestampMs: timestampMs,
      nonce: nonce,
      wrappedKey: wrappedKey,
      wrapNonce: wrapNonce,
      sphereId: sphereId,
      sphereEpoch: sphereEpoch,
    );

    final ciphertext = await SpheresCrypto.encrypt(
      key: payloadKey,
      nonce: nonce,
      plaintext: plaintext,
      aad: aad,
    );

    final signature = ed.sign(
      ed.PrivateKey(hex.decode(myIdentitySecretHex)),
      Uint8List.fromList([...aad, ...ciphertext]),
    );

    return Envelope(
      version: kEnvelopeVersion,
      mode: mode,
      type: type,
      from: from,
      sequence: sequence,
      id: id,
      timestampMs: timestampMs,
      nonce: nonce,
      ciphertext: ciphertext,
      wrappedKey: wrappedKey,
      wrapNonce: wrapNonce,
      signature: Uint8List.fromList(signature),
      sphereId: sphereId,
      sphereEpoch: sphereEpoch,
    );
  }

  /// Seal [plaintext] to every member of a sphere at once.
  ///
  /// The content key is wrapped under the sphere's epoch key, so the sender
  /// encrypts once regardless of how many members there are, and anyone
  /// holding that epoch key can open it. Members added later receive the key
  /// and can read back; members removed later cannot read anything sealed
  /// after the rotation, because they never get the next epoch's key.
  static Future<Envelope> sealToSphere({
    required String sphereId,
    required int epoch,
    required Uint8List sphereKey,
    required String type,
    required List<int> plaintext,
    required String myIdentityKey,
    required String myIdentitySecretHex,
  }) async {
    final contentKey = SpheresCrypto.randomKey();
    final wrapNonce = SpheresCrypto.randomNonce();
    final wrapped = await SpheresCrypto.encrypt(
      key: sphereKey,
      nonce: wrapNonce,
      plaintext: contentKey,
      aad: const <int>[],
    );

    return _seal(
      mode: SealMode.sphere,
      type: type,
      from: myIdentityKey,
      sequence: -1,
      payloadKey: contentKey,
      plaintext: plaintext,
      wrappedKey: wrapped,
      wrapNonce: wrapNonce,
      myIdentitySecretHex: myIdentitySecretHex,
      sphereId: sphereId,
      sphereEpoch: epoch,
    );
  }

  /// Verify and decrypt sphere-sealed content.
  ///
  /// [sphereKey] must be the key for [sphereEpoch]. The caller is responsible
  /// for checking that [from] was a member of the sphere at that epoch — the
  /// signature proves who sent it, not that they were entitled to.
  Future<Uint8List> openWithSphereKey(Uint8List sphereKey) async {
    if (mode != SealMode.sphere) {
      throw const EnvelopeException('Not a sphere-sealed envelope');
    }
    verifySignature();

    final wrapped = wrappedKey;
    final wn = wrapNonce;
    if (wrapped == null || wn == null) {
      throw const EnvelopeException('Sphere envelope has no wrapped key');
    }

    final contentKey = await SpheresCrypto.decrypt(
      key: sphereKey,
      nonce: wn,
      ciphertextWithMac: wrapped,
      aad: const <int>[],
    );
    return SpheresCrypto.decrypt(
      key: contentKey,
      nonce: nonce,
      ciphertextWithMac: ciphertext,
      aad: associatedData,
    );
  }

  // ── Opening ───────────────────────────────────────────────────────────────

  /// Verify and decrypt.
  ///
  /// [session] must be the session for [from]; the caller is responsible for
  /// looking it up by the *envelope's* sender rather than by the channel it
  /// arrived on, and for rejecting a sender that is not a member of the
  /// context the message claims to belong to.
  Future<Uint8List> open(PairwiseSession session) async {
    if (session.peerIdentityKey != from) {
      throw EnvelopeException(
        'Session is for ${session.peerIdentityKey} but envelope is from $from',
      );
    }

    verifySignature();

    switch (mode) {
      case SealMode.chain:
        final key = await session.receiving.keyFor(sequence);
        if (key == null) {
          throw const EnvelopeException(
            'No message key for this sequence — already processed or replayed',
          );
        }
        return SpheresCrypto.decrypt(
          key: key,
          nonce: nonce,
          ciphertextWithMac: ciphertext,
          aad: associatedData,
        );

      case SealMode.sphere:
        throw const EnvelopeException(
          'Sphere-sealed content needs the sphere key — use openWithSphereKey',
        );

      case SealMode.wrap:
        final wrapped = wrappedKey;
        final wn = wrapNonce;
        if (wrapped == null || wn == null) {
          throw const EnvelopeException('Wrapped envelope has no wrapped key');
        }
        final contentKey = await SpheresCrypto.decrypt(
          key: await session.wrappingKey(),
          nonce: wn,
          ciphertextWithMac: wrapped,
          aad: const <int>[],
        );
        return SpheresCrypto.decrypt(
          key: contentKey,
          nonce: nonce,
          ciphertextWithMac: ciphertext,
          aad: associatedData,
        );
    }
  }

  /// Check the sender's signature. Throws [EnvelopeException] if it fails.
  void verifySignature() {
    final Uint8List fromKey;
    try {
      fromKey = Uint8List.fromList(hex.decode(from));
    } catch (_) {
      throw const EnvelopeException('Sender key is not valid hex');
    }
    if (fromKey.length != 32) {
      throw const EnvelopeException('Sender key is not a 32-byte Ed25519 key');
    }

    final ok = ed.verify(
      ed.PublicKey(fromKey),
      Uint8List.fromList([...associatedData, ...ciphertext]),
      signature,
    );
    if (!ok) {
      throw const EnvelopeException('Signature does not verify');
    }
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'v': version,
        'mode': mode.name,
        'type': type,
        'from': from,
        'n': sequence,
        'id': id,
        'ts': timestampMs,
        'nonce': base64Encode(nonce),
        'ct': base64Encode(ciphertext),
        if (wrappedKey != null) 'wk': base64Encode(wrappedKey!),
        if (wrapNonce != null) 'wn': base64Encode(wrapNonce!),
        if (sphereId != null) 'sid': sphereId,
        if (sphereId != null) 'sep': sphereEpoch,
        'sig': base64Encode(signature),
      };

  String encode() => jsonEncode(toJson());

  static Envelope decode(String raw) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const EnvelopeException('Not a valid envelope: malformed JSON');
    }
    return fromJson(json);
  }

  static Envelope fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! int) {
      throw const EnvelopeException('Missing version');
    }
    if (version != kEnvelopeVersion) {
      throw EnvelopeException(
        'Unsupported envelope version $version (expected $kEnvelopeVersion)',
      );
    }

    SealMode? mode;
    for (final candidate in SealMode.values) {
      if (candidate.name == json['mode']) mode = candidate;
    }
    if (mode == null) {
      throw EnvelopeException('Unknown seal mode "${json['mode']}"');
    }

    Uint8List required(String field) {
      final value = json[field];
      if (value is! String) {
        throw EnvelopeException('Missing field "$field"');
      }
      try {
        return Uint8List.fromList(base64Decode(value));
      } catch (_) {
        throw EnvelopeException('Field "$field" is not valid base64');
      }
    }

    Uint8List? optional(String field) =>
        json.containsKey(field) ? required(field) : null;

    if (json['type'] is! String ||
        json['from'] is! String ||
        json['id'] is! String ||
        json['n'] is! int ||
        json['ts'] is! int) {
      throw const EnvelopeException('Envelope header is malformed');
    }

    return Envelope(
      version: version,
      mode: mode,
      type: json['type'] as String,
      from: json['from'] as String,
      sequence: json['n'] as int,
      id: json['id'] as String,
      timestampMs: json['ts'] as int,
      nonce: required('nonce'),
      ciphertext: required('ct'),
      wrappedKey: optional('wk'),
      wrapNonce: optional('wn'),
      signature: required('sig'),
      sphereId: json['sid'] as String?,
      sphereEpoch: json['sep'] as int? ?? -1,
    );
  }
}
