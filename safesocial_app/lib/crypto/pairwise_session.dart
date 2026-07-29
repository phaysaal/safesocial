import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'spheres_crypto.dart';

/// Domain separation strings. Never reuse one for a new purpose.
class _Info {
  static const root = 'spheres-pairwise-root-v1';
  static const chain = 'spheres-chain-v1';
  static const messageKey = 'spheres-msgkey-v1';
  static const chainStep = 'spheres-chainstep-v1';
  static const wrap = 'spheres-wrap-v1';
}

/// A symmetric KDF chain, advanced once per message.
///
/// Advancing derives a message key and then replaces the chain key with its
/// successor. The previous chain key is dropped, so a device compromised at
/// message N cannot derive the keys for messages before N — this is what
/// provides forward secrecy.
///
/// Post-compromise security (recovering after a key leak) additionally needs a
/// Diffie-Hellman ratchet, which is Phase 5. Do not describe this as Signal's
/// Double Ratchet in user-facing copy.
class KdfChain {
  Uint8List _chainKey;
  int _index;

  /// Message keys derived ahead of time because their messages arrived late.
  ///
  /// The relay does not guarantee ordering, so a gap does not mean loss.
  /// Bounded by [maxSkip] so a peer cannot force unbounded work or memory.
  final Map<int, Uint8List> _skipped;

  static const int maxSkip = 256;

  KdfChain._(this._chainKey, this._index, this._skipped);

  KdfChain(Uint8List seed) : this._(seed, 0, {});

  int get index => _index;
  int get skippedCount => _skipped.length;

  /// Derive the next message key and advance the chain.
  Future<({int index, Uint8List key})> next() async {
    final key = await SpheresCrypto.hkdf(
      secret: _chainKey,
      info: _Info.messageKey,
    );
    final used = _index;
    _chainKey = await SpheresCrypto.hkdf(
      secret: _chainKey,
      info: _Info.chainStep,
    );
    _index++;
    return (index: used, key: key);
  }

  /// Get the message key for [target], skipping forward if necessary.
  ///
  /// Returns null if [target] is behind the chain and was not retained — that
  /// means either a replay or a message already processed, and the caller must
  /// reject it rather than treating it as new.
  Future<Uint8List?> keyFor(int target) async {
    if (target < _index) {
      return _skipped.remove(target);
    }

    if (target - _index > maxSkip) {
      throw StateError(
        'Message $target is more than $maxSkip ahead of chain index $_index',
      );
    }

    while (_index < target) {
      final skipped = await next();
      _skipped[skipped.index] = skipped.key;
    }

    final result = await next();
    return result.key;
  }

  Map<String, dynamic> toJson() => {
        'chainKey': base64Encode(_chainKey),
        'index': _index,
        'skipped': _skipped.map((k, v) => MapEntry('$k', base64Encode(v))),
      };

  static KdfChain fromJson(Map<String, dynamic> json) {
    final skipped = <int, Uint8List>{};
    final raw = json['skipped'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final index = int.tryParse('$k');
        if (index != null && v is String) {
          skipped[index] = Uint8List.fromList(base64Decode(v));
        }
      });
    }
    return KdfChain._(
      Uint8List.fromList(base64Decode(json['chainKey'] as String)),
      json['index'] as int,
      skipped,
    );
  }
}

/// The cryptographic relationship with one contact.
///
/// Both sides derive identical state from the X25519 agreement, so there is no
/// handshake to run and nothing to negotiate — which is why this survives the
/// relay losing messages.
class PairwiseSession {
  /// Our identity (Ed25519) public key, hex.
  final String myIdentityKey;

  /// The peer's identity (Ed25519) public key, hex.
  final String peerIdentityKey;

  final Uint8List _root;

  /// Chain we encrypt with. The peer derives the same chain to decrypt.
  final KdfChain sending;

  /// Chain we decrypt the peer's messages with.
  final KdfChain receiving;

  PairwiseSession._({
    required this.myIdentityKey,
    required this.peerIdentityKey,
    required Uint8List root,
    required this.sending,
    required this.receiving,
  }) : _root = root;

  /// Establish a session from our X25519 key pair and the peer's X25519 public
  /// key.
  ///
  /// The identity keys are Ed25519 and are used for two things: salting the
  /// root derivation, and labelling the direction of each chain. Chains are
  /// keyed by the *sender's* identity so that our sending chain and the peer's
  /// receiving chain are the same chain.
  static Future<PairwiseSession> establish({
    required SimpleKeyPair myKeyExchangeKeyPair,
    required List<int> peerKeyExchangePublicKey,
    required String myIdentityKey,
    required String peerIdentityKey,
  }) async {
    final dh = await SpheresCrypto.sharedSecret(
      myKeyPair: myKeyExchangeKeyPair,
      peerPublicKeyBytes: peerKeyExchangePublicKey,
    );

    // Salt is order-independent so both sides agree without negotiating roles.
    final salt = ([myIdentityKey, peerIdentityKey]..sort()).join(':');
    final root = await SpheresCrypto.hkdf(
      secret: dh,
      salt: utf8.encode(salt),
      info: _Info.root,
    );

    return PairwiseSession._(
      myIdentityKey: myIdentityKey,
      peerIdentityKey: peerIdentityKey,
      root: root,
      sending: KdfChain(await _chainSeed(root, myIdentityKey)),
      receiving: KdfChain(await _chainSeed(root, peerIdentityKey)),
    );
  }

  static Future<Uint8List> _chainSeed(Uint8List root, String senderKey) =>
      SpheresCrypto.hkdf(secret: root, info: '${_Info.chain}:$senderKey');

  /// A static key shared by both parties, used to wrap per-item content keys.
  ///
  /// Unlike the chains this does not ratchet, so content encrypted under it has
  /// no forward secrecy. That is a deliberate trade: feed posts and album items
  /// are fanned out to many recipients and re-read long after they are sent, so
  /// they cannot use a chain that both sides advance in lockstep. Each item
  /// still gets a fresh random content key and nonce, so this key never
  /// directly encrypts user content.
  Future<Uint8List> wrappingKey() =>
      SpheresCrypto.hkdf(secret: _root, info: _Info.wrap);

  Map<String, dynamic> toJson() => {
        'v': 1,
        'myIdentityKey': myIdentityKey,
        'peerIdentityKey': peerIdentityKey,
        'root': base64Encode(_root),
        'sending': sending.toJson(),
        'receiving': receiving.toJson(),
      };

  static PairwiseSession fromJson(Map<String, dynamic> json) {
    return PairwiseSession._(
      myIdentityKey: json['myIdentityKey'] as String,
      peerIdentityKey: json['peerIdentityKey'] as String,
      root: Uint8List.fromList(base64Decode(json['root'] as String)),
      sending: KdfChain.fromJson(json['sending'] as Map<String, dynamic>),
      receiving: KdfChain.fromJson(json['receiving'] as Map<String, dynamic>),
    );
  }
}
