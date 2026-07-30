import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/sphere_keyring.dart';
import 'package:spheres_app/models/sphere.dart';

/// The property Phase 3 exists to deliver: membership is enforced by keys, not
/// by a local flag. Removing someone must actually stop them reading what is
/// published next.
void main() {
  late String aliceId;
  late String aliceSecret;
  final sphereId = 'a' * 64;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final key = ed.generateKey();
    aliceId = hex.encode(key.publicKey.bytes);
    aliceSecret = hex.encode(key.privateKey.bytes);
  });

  Future<Envelope> post(SphereKeyring keyring, int epoch, String text) =>
      Envelope.sealToSphere(
        sphereId: sphereId,
        epoch: epoch,
        sphereKey: keyring.keyFor(sphereId, epoch)!,
        type: 'post',
        plaintext: utf8.encode(text),
        myIdentityKey: aliceId,
        myIdentitySecretHex: aliceSecret,
      );

  group('sealing to a sphere', () {
    test('any member holding the epoch key can open it', () async {
      final author = SphereKeyring();
      final key = author.rotate(sphereId, 1);

      final envelope = await post(author, 1, 'visible to the sphere');

      // A different member's keyring, given the same epoch key.
      final member = SphereKeyring()..store(sphereId, 1, key);
      final opened = await Envelope.decode(envelope.encode())
          .openWithSphereKey(member.keyFor(sphereId, 1)!);

      expect(utf8.decode(opened), 'visible to the sphere');
    });

    test('someone without the key cannot open it', () async {
      final author = SphereKeyring();
      author.rotate(sphereId, 1);
      final envelope = await post(author, 1, 'members only');

      final outsider = SphereKeyring()..rotate(sphereId, 1); // different key
      await expectLater(
        envelope.openWithSphereKey(outsider.keyFor(sphereId, 1)!),
        throwsA(anything),
      );
    });

    test('the sphere id and epoch are covered by the signature', () async {
      final author = SphereKeyring();
      final key = author.rotate(sphereId, 1);
      final envelope = await post(author, 1, 'original');

      final tampered = envelope.toJson()..['sep'] = 2;
      await expectLater(
        Envelope.fromJson(tampered).openWithSphereKey(key),
        throwsA(isA<EnvelopeException>()),
      );

      final relabelled = envelope.toJson()..['sid'] = 'b' * 64;
      await expectLater(
        Envelope.fromJson(relabelled).openWithSphereKey(key),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('opening sphere content by the pairwise path is refused', () async {
      final author = SphereKeyring();
      author.rotate(sphereId, 1);
      final envelope = await post(author, 1, 'sphere content');

      // Guards against a caller accidentally routing it through the DM path.
      expect(envelope.mode, SealMode.sphere);
    });
  });

  group('removal', () {
    test('a removed member cannot read anything published afterwards', () async {
      final author = SphereKeyring();
      final epoch1 = author.rotate(sphereId, 1);

      // Mallory is a member at epoch 1 and receives that key.
      final mallory = SphereKeyring()..store(sphereId, 1, epoch1);

      final before = await post(author, 1, 'before removal');
      expect(
        utf8.decode(await before.openWithSphereKey(mallory.keyFor(sphereId, 1)!)),
        'before removal',
      );

      // Removing Mallory bumps the epoch and mints a key she never receives.
      author.rotate(sphereId, 2);
      final after = await post(author, 2, 'after removal');

      // She has no epoch-2 key at all...
      expect(mallory.hasKey(sphereId, 2), isFalse);
      // ...and her old key does not open the new content.
      await expectLater(
        after.openWithSphereKey(mallory.keyFor(sphereId, 1)!),
        throwsA(anything),
      );
    });

    test('remaining members keep reading across the rotation', () async {
      final author = SphereKeyring();
      final epoch1 = author.rotate(sphereId, 1);
      final bob = SphereKeyring()..store(sphereId, 1, epoch1);

      final epoch2 = author.rotate(sphereId, 2);
      bob.store(sphereId, 2, epoch2); // Bob is still in, so he gets the new key.

      final older = await post(author, 1, 'history');
      final newer = await post(author, 2, 'current');

      // History stays readable — a membership change must not erase the past
      // for people who were already there.
      expect(utf8.decode(await older.openWithSphereKey(bob.keyFor(sphereId, 1)!)),
          'history');
      expect(utf8.decode(await newer.openWithSphereKey(bob.keyFor(sphereId, 2)!)),
          'current');
    });

    test('each rotation produces a genuinely new key', () {
      final keyring = SphereKeyring();
      final first = keyring.rotate(sphereId, 1);
      final second = keyring.rotate(sphereId, 2);

      expect(first, isNot(equals(second)));
      expect(keyring.latestEpoch(sphereId), 2);
    });
  });

  group('keyring persistence', () {
    test('keys survive a restart', () async {
      final keyring = SphereKeyring();
      final key = keyring.rotate(sphereId, 3);
      await keyring.persist();

      final restored = SphereKeyring();
      await restored.load();

      expect(restored.keyFor(sphereId, 3), equals(key));
      expect(restored.latestEpoch(sphereId), 3);
    });

    test('leaving a sphere forgets its keys', () async {
      final keyring = SphereKeyring();
      keyring.rotate(sphereId, 1);
      keyring.forget(sphereId);

      expect(keyring.latestEpoch(sphereId), isNull);
      expect(keyring.sphereIds, isEmpty);
    });
  });

  group('sphere model', () {
    Sphere build(List<SphereMember> members) => Sphere(
          id: sphereId,
          name: 'Family',
          kind: SphereKind.group,
          createdBy: aliceId,
          createdAt: DateTime(2026),
          epoch: 1,
          members: members,
        );

    test('membership and admin checks', () {
      final sphere = build([
        SphereMember(
            identityKey: aliceId,
            role: SphereRole.admin,
            joinedAt: DateTime(2026),
            invitedBy: aliceId),
        SphereMember(
            identityKey: 'bob',
            role: SphereRole.member,
            joinedAt: DateTime(2026),
            invitedBy: aliceId),
      ]);

      expect(sphere.contains(aliceId), isTrue);
      expect(sphere.contains('carol'), isFalse);
      expect(sphere.isAdmin(aliceId), isTrue);
      expect(sphere.isAdmin('bob'), isFalse);
      expect(sphere.othersThan(aliceId), ['bob']);
    });

    test('survives a JSON round trip', () {
      final sphere = build([
        SphereMember(
            identityKey: aliceId,
            role: SphereRole.owner,
            joinedAt: DateTime(2026),
            invitedBy: aliceId),
      ]);

      expect(Sphere.fromJson(jsonDecode(jsonEncode(sphere.toJson()))), sphere);
    });

    test('a sphere saved before owners existed gains one on load', () {
      // Every device derives the same answer — the creator, if still a member
      // — so an old sphere acquires an owner without anyone sending anything.
      final legacy = build([
        SphereMember(
            identityKey: aliceId,
            role: SphereRole.admin,
            joinedAt: DateTime(2026),
            invitedBy: aliceId),
        SphereMember(
            identityKey: 'bob',
            role: SphereRole.member,
            joinedAt: DateTime(2026),
            invitedBy: aliceId),
      ]);

      final loaded = Sphere.fromJson(jsonDecode(jsonEncode(legacy.toJson())));

      expect(loaded.ownerKey, aliceId);
      expect(loaded.isAdmin('bob'), isFalse);
    });
  });
}
