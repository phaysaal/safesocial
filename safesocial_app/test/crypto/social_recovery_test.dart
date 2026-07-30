import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/shamir.dart';
import 'package:spheres_app/crypto/social_recovery.dart';

/// Social recovery was a stub that logged "Reconstruction successful
/// (simulation)". The Rust primitives behind it accepted a threshold of 1,
/// enforced no threshold on the way back, and returned garbage as success.
/// These pin all three closed.
void main() {
  late String secretHex;
  late String publicHex;

  setUp(() {
    final key = ed.generateKey();
    secretHex = hex.encode(key.privateKey.bytes);
    publicHex = hex.encode(key.publicKey.bytes);
  });

  List<RecoveryShard> shards({int guardians = 5, int threshold = 3}) =>
      SocialRecovery.createShards(
        identitySecretHex: secretHex,
        identityPublicKeyHex: publicHex,
        guardianCount: guardians,
        threshold: threshold,
      );

  group('splitting', () {
    test('produces one shard per guardian', () {
      final result = shards();

      expect(result, hasLength(5));
      expect(result.map((s) => s.index), [1, 2, 3, 4, 5]);
      expect(result.every((s) => s.threshold == 3), isTrue);
    });

    test('a threshold of 1 is refused', () {
      // It would hand every guardian a complete copy of the identity.
      expect(
        () => shards(threshold: 1),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('a threshold above the guardian count is refused', () {
      expect(
        () => shards(guardians: 2, threshold: 3),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('a secret that does not match the identity is refused up front', () {
      final other = ed.generateKey();
      expect(
        () => SocialRecovery.createShards(
          identitySecretHex: hex.encode(other.privateKey.bytes),
          identityPublicKeyHex: publicHex,
          guardianCount: 3,
          threshold: 2,
        ),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('no single shard contains the secret', () {
      final secretBytes = Uint8List.fromList(hex.decode(secretHex));

      for (final shard in shards()) {
        expect(shard.share.sublist(1), isNot(equals(secretBytes)));
      }
    });
  });

  group('reconstruction', () {
    test('exactly the threshold is enough', () {
      final all = shards(guardians: 5, threshold: 3);

      expect(SocialRecovery.reconstruct(all.take(3).toList()), secretHex);
    });

    test('any combination of the threshold works', () {
      final all = shards(guardians: 5, threshold: 3);

      expect(SocialRecovery.reconstruct([all[0], all[2], all[4]]), secretHex);
      expect(SocialRecovery.reconstruct([all[1], all[3], all[4]]), secretHex);
    });

    test('more than the threshold also works', () {
      final all = shards(guardians: 5, threshold: 3);

      expect(SocialRecovery.reconstruct(all), secretHex);
    });

    test('fewer than the threshold is refused, not silently wrong', () {
      final all = shards(guardians: 5, threshold: 3);

      // The old path returned plausible nonsense here and called it success.
      expect(
        () => SocialRecovery.reconstruct(all.take(2).toList()),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('a corrupted shard is caught by verification', () {
      final all = shards(guardians: 3, threshold: 2);
      all[0].share[5] ^= 0xff;

      expect(
        () => SocialRecovery.reconstruct(all),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('shards from different identities are refused', () {
      final mine = shards(guardians: 3, threshold: 2);

      final otherKey = ed.generateKey();
      final theirs = SocialRecovery.createShards(
        identitySecretHex: hex.encode(otherKey.privateKey.bytes),
        identityPublicKeyHex: hex.encode(otherKey.publicKey.bytes),
        guardianCount: 3,
        threshold: 2,
      );

      expect(
        () => SocialRecovery.reconstruct([mine.first, theirs.first]),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('the same shard twice is refused', () {
      // Duplicate x-coordinates made the Rust implementation panic.
      final all = shards(guardians: 3, threshold: 2);

      expect(
        () => SocialRecovery.reconstruct([all[0], all[0]]),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('mismatched shard lengths are refused rather than crashing', () {
      final all = shards(guardians: 3, threshold: 2);
      final truncated = RecoveryShard(
        index: all[1].index,
        shareCount: all[1].shareCount,
        threshold: all[1].threshold,
        identityPublicKey: all[1].identityPublicKey,
        share: all[1].share.sublist(0, 10),
      );

      expect(
        () => SocialRecovery.reconstruct([all[0], truncated]),
        throwsA(isA<RecoveryException>()),
      );
    });

    test('no shards at all is refused', () {
      expect(
        () => SocialRecovery.reconstruct([]),
        throwsA(isA<RecoveryException>()),
      );
    });
  });

  group('shard encoding', () {
    test('round trips', () {
      final original = shards().first;
      final decoded = RecoveryShard.tryDecode(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.index, original.index);
      expect(decoded.threshold, original.threshold);
      expect(decoded.identityPublicKey, original.identityPublicKey);
      expect(decoded.share, original.share);
    });

    test('encoded shards survive a full recovery', () {
      final encoded = shards(guardians: 4, threshold: 2).map((s) => s.encode());
      final decoded =
          encoded.map(RecoveryShard.tryDecode).whereType<RecoveryShard>();

      expect(SocialRecovery.reconstruct(decoded.take(2).toList()), secretHex);
    });

    test('surrounding whitespace is tolerated', () {
      final encoded = '  ${shards().first.encode()}\n';

      expect(RecoveryShard.tryDecode(encoded), isNotNull);
    });

    test('malformed input decodes to null instead of throwing', () {
      expect(RecoveryShard.tryDecode('nonsense'), isNull);
      expect(RecoveryShard.tryDecode('spheres-shard:!!!'), isNull);
      expect(RecoveryShard.tryDecode(''), isNull);
    });
  });

  group('shamir primitive', () {
    test('splitting an empty secret is refused', () {
      expect(
        () => Shamir.split(
            secret: Uint8List(0), shareCount: 3, threshold: 2),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('more than 255 shares is refused', () {
      expect(
        () => Shamir.split(
            secret: Uint8List(4), shareCount: 256, threshold: 2),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('round trips arbitrary bytes including zeros', () {
      final secret = Uint8List.fromList([0, 0, 255, 7, 0, 128]);
      final parts = Shamir.split(secret: secret, shareCount: 4, threshold: 2);

      expect(Shamir.combine([parts[3], parts[1]]), equals(secret));
    });
  });
}
