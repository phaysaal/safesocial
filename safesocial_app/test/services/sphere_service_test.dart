import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Membership changes used to be local-only mutations that never reached
/// anyone. Now they are signed statements, so what matters is that a peer
/// cannot forge one, cannot make one they lack the authority for, and cannot
/// replay an old one.
void main() {
  late ed.KeyPair aliceKey;
  late ed.KeyPair malloryKey;
  late String alice;
  late String aliceSecret;
  late String mallory;
  late String mallorySecret;
  late String bob;

  String idOf(ed.KeyPair k) => hex.encode(k.publicKey.bytes);
  String secretOf(ed.KeyPair k) => hex.encode(k.privateKey.bytes);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    aliceKey = ed.generateKey();
    malloryKey = ed.generateKey();
    alice = idOf(aliceKey);
    aliceSecret = secretOf(aliceKey);
    mallory = idOf(malloryKey);
    mallorySecret = secretOf(malloryKey);
    bob = idOf(ed.generateKey());
  });

  /// A service acting as [identity], with no transport attached.
  SphereService serviceFor(String identity, String secret) {
    final service = SphereService();
    service.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return service;
  }

  SphereMember member(String key, SphereRole role) => SphereMember(
        identityKey: key,
        role: role,
        joinedAt: DateTime(2026),
        invitedBy: alice,
      );

  /// Build a signed op payload as [author] would send it.
  String signedOp({
    required String sphereId,
    required int epoch,
    required String op,
    required String target,
    required String author,
    required String authorSecret,
    required List<SphereMember> members,
    String name = 'Family',
  }) {
    final membershipOp = MembershipOp(
      sphereId: sphereId,
      epoch: epoch,
      op: op,
      target: target,
      by: author,
      timestampMs: DateTime(2026).millisecondsSinceEpoch,
      members: members,
      name: name,
      kind: SphereKind.group,
    );
    final signature = ed.sign(
      ed.PrivateKey(hex.decode(authorSecret)),
      membershipOp.signedBytes(),
    );
    return jsonEncode({
      'op': membershipOp.toJson(),
      'signature': hex.encode(signature),
    });
  }

  group('creating', () {
    test('the creator is an admin and holds the first key', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      expect(sphere.epoch, 1);
      expect(sphere.isAdmin(alice), isTrue);
      expect(sphere.contains(bob), isTrue);
      expect(service.keyring.hasKey(sphere.id, 1), isTrue);
      expect(service.writable.map((s) => s.id), [sphere.id]);
    });

    test('sphere ids are unguessable and unique', () async {
      final service = serviceFor(alice, aliceSecret);
      final a = await service.create(name: 'A', kind: SphereKind.group);
      final b = await service.create(name: 'B', kind: SphereKind.group);

      expect(a.id, isNot(b.id));
      expect(a.id.length, 64); // 256 bits of hex
    });
  });

  group('membership changes rotate the key', () {
    test('adding a member bumps the epoch and mints a new key', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);
      final firstKey = service.keyring.keyFor(sphere.id, 1);

      await service.addMember(sphere.id, bob);

      final updated = service.sphere(sphere.id)!;
      expect(updated.epoch, 2);
      expect(updated.contains(bob), isTrue);
      expect(service.keyring.keyFor(sphere.id, 2), isNot(equals(firstKey)));
    });

    test('removing a member bumps the epoch', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      await service.removeMember(sphere.id, bob);

      final updated = service.sphere(sphere.id)!;
      expect(updated.contains(bob), isFalse);
      expect(updated.epoch, 2);
      expect(service.keyring.hasKey(sphere.id, 2), isTrue);
    });

    test('a non-admin cannot change membership', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      // Bob's own device, holding the same sphere but as a plain member.
      final bobService = serviceFor(bob, secretOf(ed.generateKey()));
      await bobService.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphere.id,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [member(alice, SphereRole.admin), member(bob, SphereRole.member)],
        ),
      );
      await bobService.acceptInvite(sphere.id);

      expect(
        () => bobService.removeMember(sphere.id, alice),
        throwsA(isA<StateError>()),
      );
    });

    test('leaving discards the keys', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      await service.leave(sphere.id);

      expect(service.sphere(sphere.id), isNull);
      expect(service.keyring.hasKey(sphere.id, 1), isFalse);
    });
  });

  group('inbound operations', () {
    const sphereId =
        '1111111111111111111111111111111111111111111111111111111111111111';

    Future<SphereService> bobWithSphere() async {
      final service = serviceFor(bob, secretOf(ed.generateKey()));
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
          ],
        ),
      );
      await service.acceptInvite(sphereId);
      return service;
    }

    test('a signed create arrives as an invitation, not a membership', () async {
      final service = serviceFor(bob, secretOf(ed.generateKey()));
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
          ],
        ),
      );

      // Nobody joins a sphere without agreeing to.
      expect(service.sphere(sphereId), isNull);
      expect(service.invites.map((i) => i.sphere.id), [sphereId]);
      expect(service.invites.single.invitedBy, alice);
    });

    test('accepting an invitation joins the sphere', () async {
      final service = await bobWithSphere();

      final sphere = service.sphere(sphereId);
      expect(sphere, isNotNull);
      expect(sphere!.name, 'Family');
      expect(sphere.isAdmin(alice), isTrue);
      expect(service.invites, isEmpty);
    });

    test('declining discards the invitation and its key', () async {
      final service = serviceFor(bob, secretOf(ed.generateKey()));
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
          ],
        ),
      );

      await service.declineInvite(sphereId);

      expect(service.invites, isEmpty);
      expect(service.sphere(sphereId), isNull);
      expect(service.keyring.hasKey(sphereId, 1), isFalse);
    });

    test('a create we are not named in is ignored', () async {
      final service = serviceFor(bob, secretOf(ed.generateKey()));
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [member(alice, SphereRole.admin)],
        ),
      );

      expect(service.sphere(sphereId), isNull);
      expect(service.invites, isEmpty);
    });

    test('an op whose author disagrees with the sender is rejected', () async {
      final service = await bobWithSphere();

      // Mallory relays an op that claims to be from Alice. The envelope layer
      // proves the sender is Mallory, so the mismatch is caught.
      await service.handleIncomingOp(
        mallory,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opAdd,
          target: mallory,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(mallory, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(mallory), isFalse);
      expect(service.sphere(sphereId)!.epoch, 1);
    });

    test('an op signed by a non-admin is rejected', () async {
      final service = await bobWithSphere();

      // Mallory signs her own op, honestly, but she is not a member at all.
      await service.handleIncomingOp(
        mallory,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opAdd,
          target: mallory,
          author: mallory,
          authorSecret: mallorySecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(mallory, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(mallory), isFalse);
    });

    test('a forged signature is rejected', () async {
      final service = await bobWithSphere();

      final payload = jsonDecode(signedOp(
        sphereId: sphereId,
        epoch: 2,
        op: MembershipOp.opAdd,
        target: mallory,
        author: alice,
        authorSecret: aliceSecret,
        members: [
          member(alice, SphereRole.admin),
          member(bob, SphereRole.member),
          member(mallory, SphereRole.member),
        ],
      )) as Map<String, dynamic>;

      // Same op, signature from the wrong key.
      payload['signature'] = hex.encode(ed.sign(
        ed.PrivateKey(hex.decode(mallorySecret)),
        Uint8List.fromList(utf8.encode('anything')),
      ));

      await service.handleIncomingOp(alice, jsonEncode(payload));

      expect(service.sphere(sphereId)!.contains(mallory), isFalse);
    });

    test('replaying an older epoch is ignored', () async {
      final service = await bobWithSphere();

      // Advance to epoch 2 legitimately.
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opAdd,
          target: mallory,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(mallory, SphereRole.member),
          ],
        ),
      );
      expect(service.sphere(sphereId)!.epoch, 2);

      // Replaying epoch 1 must not roll membership back.
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [member(alice, SphereRole.admin), member(bob, SphereRole.member)],
        ),
      );

      expect(service.sphere(sphereId)!.epoch, 2);
      expect(service.sphere(sphereId)!.contains(mallory), isTrue);
    });

    test('being removed drops the sphere and its keys', () async {
      final service = await bobWithSphere();

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: bob,
          author: alice,
          authorSecret: aliceSecret,
          members: [member(alice, SphereRole.admin)],
        ),
      );

      expect(service.sphere(sphereId), isNull);
      expect(service.keyring.hasKey(sphereId, 1), isFalse);
    });

    test('a member can only remove themselves by leaving', () async {
      final service = await bobWithSphere();

      // Mallory is not even in this sphere; a leave naming someone else must
      // not take effect.
      await service.handleIncomingOp(
        mallory,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opLeave,
          target: alice,
          author: mallory,
          authorSecret: mallorySecret,
          members: [member(bob, SphereRole.member)],
        ),
      );

      expect(service.sphere(sphereId)!.contains(alice), isTrue);
    });
  });

  group('content', () {
    test('content from a non-member is refused even if validly signed', () async {
      final alicesService = serviceFor(alice, aliceSecret);
      final sphere =
          await alicesService.create(name: 'Family', kind: SphereKind.group);

      // Mallory holds the epoch key somehow, and signs honestly — but she is
      // not a member, so the content must not be accepted.
      final mallorysService = serviceFor(mallory, mallorySecret);
      await mallorysService.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphere.id,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.admin),
            member(mallory, SphereRole.member),
          ],
        ),
      );
      await mallorysService.acceptInvite(sphere.id);
      mallorysService.keyring
          .store(sphere.id, 1, alicesService.keyring.keyFor(sphere.id, 1)!);

      final sealed = await mallorysService.sealContent(
        sphereId: sphere.id,
        type: 'post',
        plaintext: 'I do not belong here',
      );

      // Alice's copy of the sphere does not list Mallory.
      await expectLater(
        alicesService.openContent(sealed),
        throwsA(isA<Exception>()),
      );
    });

    test('a member can seal and the author can reopen', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      final sealed = await service.sealContent(
        sphereId: sphere.id,
        type: 'post',
        plaintext: 'hello sphere',
      );

      expect(await service.openContent(sealed), 'hello sphere');
    });

    test('sealing without the current epoch key fails loudly', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      // Simulate having missed the rotation.
      service.keyring.forget(sphere.id);

      await expectLater(
        service.sealContent(
            sphereId: sphere.id, type: 'post', plaintext: 'nope'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
