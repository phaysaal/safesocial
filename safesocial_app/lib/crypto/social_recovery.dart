import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'shamir.dart';

class RecoveryException implements Exception {
  final String message;
  const RecoveryException(this.message);
  @override
  String toString() => 'RecoveryException: $message';
}

/// One guardian's share of an identity.
///
/// Carries the identity's *public* key, which is not a secret and is what
/// makes verification possible: a reconstruction can be checked against it
/// before anything adopts the result.
class RecoveryShard {
  static const String prefix = 'spheres-shard:';
  static const int version = 1;

  /// Which share this is, for the user's benefit ("share 2 of 5").
  final int index;
  final int shareCount;
  final int threshold;

  /// Ed25519 public key of the identity this reconstructs, hex.
  final String identityPublicKey;

  final Uint8List share;

  const RecoveryShard({
    required this.index,
    required this.shareCount,
    required this.threshold,
    required this.identityPublicKey,
    required this.share,
  });

  String encode() => '$prefix${base64Url.encode(utf8.encode(jsonEncode({
        'v': version,
        'i': index,
        'n': shareCount,
        'k': threshold,
        'pub': identityPublicKey,
        'd': base64Url.encode(share),
      })))}';

  /// Parse a shard. Returns null for anything malformed rather than throwing,
  /// so one bad paste does not abort a recovery attempt.
  static RecoveryShard? tryDecode(String value) {
    final trimmed = value.trim();
    if (!trimmed.startsWith(prefix)) return null;
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(trimmed.substring(prefix.length))),
      ) as Map<String, dynamic>;

      if (json['v'] != version) return null;

      final share = Uint8List.fromList(base64Url.decode(json['d'] as String));
      if (share.length < 2) return null;

      return RecoveryShard(
        index: json['i'] as int,
        shareCount: json['n'] as int,
        threshold: json['k'] as int,
        identityPublicKey: json['pub'] as String,
        share: share,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Splitting an identity across guardians, and putting it back together.
///
/// The rule that matters: a reconstruction is never returned unless it
/// verifies against the identity's public key. Shamir has no integrity of its
/// own — too few shares, or one wrong share, yields plausible nonsense — and
/// the previous implementation returned exactly that as a success, so a user
/// could "recover" an identity that was not theirs and could never be used.
class SocialRecovery {
  const SocialRecovery._();

  /// Split an identity secret into guardian shards.
  ///
  /// [identitySecretHex] is the 64-byte Ed25519 private key; [threshold] is how
  /// many guardians must cooperate.
  static List<RecoveryShard> createShards({
    required String identitySecretHex,
    required String identityPublicKeyHex,
    required int guardianCount,
    required int threshold,
  }) {
    if (threshold < Shamir.minThreshold) {
      throw const RecoveryException(
        'At least 2 guardians must be required. With a threshold of 1 every '
        'guardian would hold your whole identity on their own.',
      );
    }
    if (guardianCount < threshold) {
      throw RecoveryException(
        'You cannot require $threshold guardians when only $guardianCount hold '
        'a share.',
      );
    }

    final Uint8List secret;
    try {
      secret = Uint8List.fromList(hex.decode(identitySecretHex));
    } catch (_) {
      throw const RecoveryException('Identity key is not valid hex');
    }

    // Fail now rather than at recovery time, when it is too late to matter.
    if (!_derivesTo(secret, identityPublicKeyHex)) {
      throw const RecoveryException(
        'This secret does not match the identity it claims to be',
      );
    }

    final shares = Shamir.split(
      secret: secret,
      shareCount: guardianCount,
      threshold: threshold,
    );

    return [
      for (var i = 0; i < shares.length; i++)
        RecoveryShard(
          index: i + 1,
          shareCount: guardianCount,
          threshold: threshold,
          identityPublicKey: identityPublicKeyHex,
          share: shares[i],
        ),
    ];
  }

  /// Rebuild an identity secret from collected shards.
  ///
  /// Throws unless the result verifies against the public key the shards name.
  static String reconstruct(List<RecoveryShard> shards) {
    if (shards.isEmpty) {
      throw const RecoveryException('No shards supplied');
    }

    final expectedKey = shards.first.identityPublicKey;
    if (shards.any((s) => s.identityPublicKey != expectedKey)) {
      throw const RecoveryException(
        'These shards are for different identities',
      );
    }

    final threshold = shards.first.threshold;
    if (shards.length < threshold) {
      throw RecoveryException(
        'Need $threshold shards to recover this identity; you have '
        '${shards.length}.',
      );
    }

    final Uint8List secret;
    try {
      secret = Shamir.combine(shards.map((s) => s.share).toList());
    } on ArgumentError catch (e) {
      throw RecoveryException(e.message.toString());
    }

    // The load-bearing check. Shamir will happily return nonsense.
    if (!_derivesTo(secret, expectedKey)) {
      throw const RecoveryException(
        'The shards did not reconstruct this identity. One of them is wrong, '
        'or they came from different backups.',
      );
    }

    return hex.encode(secret);
  }

  /// Whether [secret] really is the private key for [publicKeyHex].
  ///
  /// This recomputes the public key from the seed rather than reading the
  /// copy stored in the second half of the key. `ed.public()` only slices
  /// bytes 32..64, so trusting it would validate half the secret and miss
  /// corruption in the seed entirely — producing a keypair whose seed and
  /// public half disagree, which verifies here but fails on every real
  /// signature. Both halves are checked.
  static bool _derivesTo(Uint8List secret, String publicKeyHex) {
    try {
      if (secret.length != 64) return false;

      final derived = ed.public(ed.newKeyFromSeed(secret.sublist(0, 32)));
      final derivedHex = hex.encode(derived.bytes).toLowerCase();

      final embeddedHex = hex.encode(secret.sublist(32)).toLowerCase();

      return derivedHex == publicKeyHex.toLowerCase() &&
          derivedHex == embeddedHex;
    } catch (_) {
      return false;
    }
  }
}
