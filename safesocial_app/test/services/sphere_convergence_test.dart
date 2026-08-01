import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Two admins can change a sphere at the same moment, neither having seen the
/// other. Both operations then claim the same epoch.
///
/// That used to be silent data loss: the second to arrive was discarded as a
/// replay, so devices that saw the two in different orders ended up with
/// different member lists — permanently, with nothing to notice it. Everything
/// governance rests on that member list, so it had to converge.
///
/// The rule is that both devices compare the same two operations and reach the
/// same answer. These tests deliver the same pair in both orders and require
/// the results to be identical.
void main() {
  late String alice, aliceSecret;
  late String bob, bobSecret;
  late String carol, dave, erin;

  const sphereId =
      '1111111111111111111111111111111111111111111111111111111111111111';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();

    final a = ed.generateKey();
    final b = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(b.publicKey.bytes);
    bobSecret = hex.encode(b.privateKey.bytes);
    carol = hex.encode(ed.generateKey().publicKey.bytes);
    dave = hex.encode(ed.generateKey().publicKey.bytes);
    erin = hex.encode(ed.generateKey().publicKey.bytes);
  });

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

  /// Alice owns; Bob is a co-admin; Carol and Dave are members.
  List<SphereMember> startingMembers() => [
        member(alice, SphereRole.owner),
        member(bob, SphereRole.admin),
        member(carol, SphereRole.member),
        member(dave, SphereRole.member),
        // A bystander, so the two observers in these tests are people neither
        // change touches.
        member(erin, SphereRole.member),
      ];

  String signedOp({
    required int epoch,
    required String op,
    required String target,
    required String author,
    required String authorSecret,
    required List<SphereMember> members,
    required DateTime at,
    String name = 'Crew',
  }) {
    final membershipOp = MembershipOp(
      sphereId: sphereId,
      epoch: epoch,
      op: op,
      target: target,
      by: author,
      timestampMs: at.millisecondsSinceEpoch,
      members: members,
      name: name,
      kind: SphereKind.group,
    );
    return jsonEncode({
      'op': membershipOp.toJson(),
      'signature': hex.encode(ed.sign(
        ed.PrivateKey(hex.decode(authorSecret)),
        membershipOp.signedBytes(),
      )),
    });
  }

  /// A device belonging to [who], already in the sphere at epoch 1.
  Future<SphereService> deviceFor(String who, String secret) async {
    final service = serviceFor(who, secret);
    await service.handleIncomingOp(
      alice,
      signedOp(
        epoch: 1,
        op: MembershipOp.opCreate,
        target: '',
        author: alice,
        authorSecret: aliceSecret,
        members: startingMembers(),
        at: DateTime(2026, 8, 1, 9),
      ),
    );
    await service.acceptInvite(sphereId);
    return service;
  }

  // Alice removes Dave. Bob, at the same moment, promotes Carol. Both claim
  // epoch 2, and Alice's is a second earlier.
  String aliceRemovesDave() => signedOp(
        epoch: 2,
        op: MembershipOp.opRemove,
        target: dave,
        author: alice,
        authorSecret: aliceSecret,
        at: DateTime(2026, 8, 1, 10, 0, 0),
        members: [
          member(alice, SphereRole.owner),
          member(bob, SphereRole.admin),
          member(carol, SphereRole.member),
          member(erin, SphereRole.member),
        ],
      );

  String bobPromotesCarol() => signedOp(
        epoch: 2,
        op: MembershipOp.opPromote,
        target: carol,
        author: bob,
        authorSecret: bobSecret,
        at: DateTime(2026, 8, 1, 10, 0, 1),
        members: [
          member(alice, SphereRole.owner),
          member(bob, SphereRole.admin),
          member(carol, SphereRole.admin),
          member(dave, SphereRole.member),
          member(erin, SphereRole.member),
        ],
      );

  String describe(Sphere sphere) {
    final parts = sphere.members
        .map((m) => '${m.identityKey}:${m.role.name}')
        .toList()
      ..sort();
    return 'epoch=${sphere.epoch} ${parts.join(',')}';
  }

  group('two changes claiming the same epoch', () {
    test('converge regardless of the order they arrive in', () async {
      // The whole point. Carol's device sees Alice then Bob; Dave's device
      // sees Bob then Alice. They must agree.
      final carolsDevice = await deviceFor(carol, aliceSecret);
      final erinsDevice = await deviceFor(erin, aliceSecret);

      await carolsDevice.handleIncomingOp(alice, aliceRemovesDave());
      await carolsDevice.handleIncomingOp(bob, bobPromotesCarol());

      await erinsDevice.handleIncomingOp(bob, bobPromotesCarol());
      await erinsDevice.handleIncomingOp(alice, aliceRemovesDave());

      expect(describe(carolsDevice.sphere(sphereId)!),
          describe(erinsDevice.sphere(sphereId)!));
    });

    test('the earlier change is the one that stands', () async {
      final device = await deviceFor(carol, aliceSecret);

      await device.handleIncomingOp(bob, bobPromotesCarol());
      await device.handleIncomingOp(alice, aliceRemovesDave());

      // Alice's was a second earlier, so Dave goes and Carol is not promoted.
      final sphere = device.sphere(sphereId)!;
      expect(sphere.contains(dave), isFalse);
      expect(sphere.memberFor(carol)!.isAdmin, isFalse);
    });

    test('a later sibling does not overwrite an earlier one', () async {
      final device = await deviceFor(carol, aliceSecret);

      await device.handleIncomingOp(alice, aliceRemovesDave());
      await device.handleIncomingOp(bob, bobPromotesCarol());

      expect(device.sphere(sphereId)!.contains(dave), isFalse);
    });

    test('the superseded change is recorded, not hidden', () async {
      // An admin action that quietly evaporates is exactly what members cannot
      // be expected to trust.
      final device = await deviceFor(carol, aliceSecret);

      await device.handleIncomingOp(bob, bobPromotesCarol());
      await device.handleIncomingOp(alice, aliceRemovesDave());

      expect(device.eventsFor(sphereId).map((e) => e.op),
          contains('superseded'));
    });

    test('applying the same operation twice changes nothing', () async {
      final device = await deviceFor(carol, aliceSecret);
      await device.handleIncomingOp(alice, aliceRemovesDave());
      final before = describe(device.sphere(sphereId)!);

      await device.handleIncomingOp(alice, aliceRemovesDave());

      expect(describe(device.sphere(sphereId)!), before);
    });

    test('identical timestamps still resolve the same way everywhere',
        () async {
      // Wall clocks can agree exactly. The tie then falls to the hash, which
      // is arbitrary but identical on every device.
      final sameMoment = DateTime(2026, 8, 1, 11);
      final one = signedOp(
        epoch: 2,
        op: MembershipOp.opRemove,
        target: dave,
        author: alice,
        authorSecret: aliceSecret,
        at: sameMoment,
        members: [
          member(alice, SphereRole.owner),
          member(bob, SphereRole.admin),
          member(carol, SphereRole.member),
          member(erin, SphereRole.member),
        ],
      );
      final two = signedOp(
        epoch: 2,
        op: MembershipOp.opPromote,
        target: carol,
        author: bob,
        authorSecret: bobSecret,
        at: sameMoment,
        members: [
          member(alice, SphereRole.owner),
          member(bob, SphereRole.admin),
          member(carol, SphereRole.admin),
          member(dave, SphereRole.member),
          member(erin, SphereRole.member),
        ],
      );

      final first = await deviceFor(carol, aliceSecret);
      final second = await deviceFor(erin, aliceSecret);
      await first.handleIncomingOp(alice, one);
      await first.handleIncomingOp(bob, two);
      await second.handleIncomingOp(bob, two);
      await second.handleIncomingOp(alice, one);

      expect(describe(first.sphere(sphereId)!),
          describe(second.sphere(sphereId)!));
    });

    test('a sibling that wins is still refused if it was never allowed',
        () async {
      // Winning a tie does not confer authority. Dave is a plain member.
      final device = await deviceFor(carol, aliceSecret);
      await device.handleIncomingOp(bob, bobPromotesCarol());

      await device.handleIncomingOp(
        dave,
        signedOp(
          epoch: 2,
          op: MembershipOp.opRemove,
          target: alice,
          author: dave,
          authorSecret: aliceSecret, // signature will not match dave
          at: DateTime(2026, 8, 1, 9, 59),
          members: [member(dave, SphereRole.owner)],
        ),
      );

      expect(device.sphere(sphereId)!.contains(alice), isTrue);
    });

    test('a removal that wins still removes us', () async {
      // Carol's own device must honour the winner even when the winner is the
      // one that ejects her.
      final carolsDevice = await deviceFor(carol, aliceSecret);
      await carolsDevice.handleIncomingOp(bob, bobPromotesCarol());

      await carolsDevice.handleIncomingOp(
        alice,
        signedOp(
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: alice,
          authorSecret: aliceSecret,
          at: DateTime(2026, 8, 1, 9, 59),
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.admin),
            member(dave, SphereRole.member),
            member(erin, SphereRole.member),
          ],
        ),
      );

      expect(carolsDevice.sphere(sphereId), isNull);
    });
  });

  group('the losing author', () {
    test('puts their change back when it was theirs to make', () async {
      // Bob's promotion of Carol lost to Alice's removal of Dave. Bob should
      // not have to notice and redo it by hand.
      final bobsDevice = await deviceFor(bob, bobSecret);
      final sent = <String>[];
      bobsDevice.sendToPeer = (peer, payload) async {
        sent.add(payload);
        return true;
      };

      await bobsDevice.promote(sphereId, carol);
      expect(bobsDevice.sphere(sphereId)!.memberFor(carol)!.isAdmin, isTrue);

      // Alice's earlier change arrives and wins.
      await bobsDevice.handleIncomingOp(alice, aliceRemovesDave());

      final sphere = bobsDevice.sphere(sphereId)!;
      expect(sphere.contains(dave), isFalse, reason: "Alice's change stands");
      // And Bob's intent survives, at the next epoch.
      expect(sphere.memberFor(carol)!.isAdmin, isTrue);
      expect(sphere.epoch, 3);
    });

    test('does not retry a change the winner already made', () async {
      // Both admins remove Dave at once. There is nothing left to redo.
      final bobsDevice = await deviceFor(bob, bobSecret);
      bobsDevice.sendToPeer = (peer, payload) async => true;

      await bobsDevice.removeMember(sphereId, dave);
      await bobsDevice.handleIncomingOp(alice, aliceRemovesDave());

      final sphere = bobsDevice.sphere(sphereId)!;
      expect(sphere.contains(dave), isFalse);
      // Epoch 2, not 3: no pointless re-key.
      expect(sphere.epoch, 2);
    });
  });
}
