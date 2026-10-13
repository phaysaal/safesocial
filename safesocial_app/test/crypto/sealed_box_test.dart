import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/sealed_box.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/media_lock.dart';

/// A small secret sealed to one exchange key, and a key cut into shares that
/// all have to come back. Both carry a picture's key to the people in it.
void main() {
  group('the sealed box', () {
    test('opens for the key it was sealed to and for nobody else', () async {
      final bob = await SpheresCrypto.newKeyExchangeKeyPair();
      final eve = await SpheresCrypto.newKeyExchangeKeyPair();
      final bobHex = hex.encode((await bob.extractPublicKey()).bytes);
      final secret = SpheresCrypto.randomBytes(32);
      final box = await SealedBox.seal(peerExchangeKeyHex: bobHex, plaintext: secret);

      expect(await SealedBox.open(myKeyPair: bob, box: box), secret);
      expect(await SealedBox.open(myKeyPair: eve, box: box), isNull);
      expect(await SealedBox.open(myKeyPair: bob, box: 'not a box'), isNull);

      // One flipped byte in the ciphertext and the box refuses.
      final bytes = Uint8List.fromList(base64ToBytes(box));
      bytes[bytes.length - 1] ^= 1;
      expect(await SealedBox.open(myKeyPair: bob, box: bytesToBase64(bytes)), isNull);

      final again = await SealedBox.seal(peerExchangeKeyHex: bobHex, plaintext: secret);
      expect(again, isNot(box), reason: 'a fresh ephemeral key every time');
    });
  });

  group('key shares', () {
    test('all of them join back to the key, any fewer say nothing', () {
      final seed = SpheresCrypto.randomBytes(32);
      final shares = LockedItem.split(seed, 3);
      expect(shares.length, 3);
      expect(LockedItem.join(shares), seed);
      expect(LockedItem.join(shares.sublist(0, 2)), isNot(seed));
      expect(LockedItem.split(seed, 1).single, seed, reason: 'one person: the key itself');
    });

    test('an item is complete only when every tagged person has released', () {
      const item = LockedItem(keys: {
        'bob': SealedKeys(seed: 'x', share: 'y'),
        'carol': SealedKeys(seed: 'x', share: 'y'),
      });
      expect(item.complete, isFalse);
      expect(item.waiting, {'bob', 'carol'});
      final one = item.withRelease('bob', 'AA==');
      expect(one.waiting, {'carol'});
      expect(one.seed, isNull);
      final both = one.withRelease('carol', 'AQ==');
      expect(both.complete, isTrue);
      expect(both.seed, [1]);
      // A release from someone not tagged is not even representable.
      expect(LockedItem.fromJson({
        'keys': {'bob': {'seed': 'x', 'share': 'y'}},
        'released': {'dave': 'zz'},
      }).released, isEmpty);
    });
  });
}

List<int> base64ToBytes(String s) => Uri.parse('data:;base64,$s').data!.contentAsBytes();
String bytesToBase64(List<int> b) => UriData.fromBytes(b).contentText;
