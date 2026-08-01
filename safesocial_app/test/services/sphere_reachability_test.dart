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

/// A member used to be able to reach only whoever invited them: everyone else
/// in the sphere was a name with no way to derive a shared secret, so content
/// could only ever flow from its author. If the author was away, or the relay
/// had already dropped their copy, there was nobody else to ask.
///
/// Member lists now carry each member's X25519 key, which is what makes asking
/// a peer possible at all.
void main() {
  late String alice, aliceSecret, aliceX;
  late String bob, bobX;
  late String carol, carolX;

  const sphereId =
      '2222222222222222222222222222222222222222222222222222222222222222';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();

    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    aliceX = 'a1' * 32;
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    bobX = 'b2' * 32;
    carol = hex.encode(ed.generateKey().publicKey.bytes);
    carolX = 'c3' * 32;
  });

  /// A device that knows [known] contacts' exchange keys from its address book.
  SphereService serviceFor(
    String identity,
    String secret, {
    String? myExchange,
    Map<String, String> known = const {},
  }) {
    final service = SphereService();
    service.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (k) => known[k],
      myExchangeKey: myExchange,
    );
    return service;
  }

  SphereMember member(String key, SphereRole role, {String? exchange}) =>
      SphereMember(
        identityKey: key,
        role: role,
        joinedAt: DateTime(2026),
        invitedBy: alice,
        keyExchangePublicKey: exchange,
      );

  String signedCreate(List<SphereMember> members) {
    final op = MembershipOp(
      sphereId: sphereId,
      epoch: 1,
      op: MembershipOp.opCreate,
      target: '',
      by: alice,
      timestampMs: DateTime(2026, 8, 1).millisecondsSinceEpoch,
      members: members,
      name: 'Crew',
      kind: SphereKind.group,
    );
    return jsonEncode({
      'op': op.toJson(),
      'signature': hex.encode(
          ed.sign(ed.PrivateKey(hex.decode(aliceSecret)), op.signedBytes())),
    });
  }

  group('member lists carry keys', () {
    test('the creator records everyone they can, including themselves',
        () async {
      final service = serviceFor(alice, aliceSecret,
          myExchange: aliceX, known: {bob: bobX, carol: carolX});

      final sphere = await service.create(
        name: 'Crew',
        kind: SphereKind.group,
        initialMembers: [bob, carol],
      );

      expect(sphere.memberFor(alice)!.keyExchangePublicKey, aliceX);
      expect(sphere.memberFor(bob)!.keyExchangePublicKey, bobX);
      expect(sphere.memberFor(carol)!.keyExchangePublicKey, carolX);
    });

    test('someone whose key we do not know is still added', () async {
      // Not knowing a key must not stop somebody joining; it only means we
      // cannot reach them directly yet.
      final service =
          serviceFor(alice, aliceSecret, myExchange: aliceX, known: {bob: bobX});

      final sphere = await service.create(
        name: 'Crew',
        kind: SphereKind.group,
        initialMembers: [bob, carol],
      );

      expect(sphere.contains(carol), isTrue);
      expect(sphere.memberFor(carol)!.keyExchangePublicKey, isNull);
    });

    test('a key survives a round trip through storage', () async {
      final original = member(bob, SphereRole.member, exchange: bobX);

      final restored = SphereMember.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(restored.keyExchangePublicKey, bobX);
    });

    test('a member list written before keys existed still reads', () async {
      final json = {
        'identityKey': bob,
        'role': 'member',
        'joinedAt': DateTime(2026).toIso8601String(),
        'invitedBy': alice,
      };

      expect(SphereMember.fromJson(json).keyExchangePublicKey, isNull);
    });
  });

  group('reaching a peer', () {
    /// Carol's device, which knows nobody: everything must come from the
    /// member list.
    Future<SphereService> carolsDevice() async {
      final service = serviceFor(carol, aliceSecret);
      await service.handleIncomingOp(
        alice,
        signedCreate([
          member(alice, SphereRole.owner, exchange: aliceX),
          member(bob, SphereRole.member, exchange: bobX),
          member(carol, SphereRole.member, exchange: carolX),
        ]),
      );
      await service.acceptInvite(sphereId);
      return service;
    }

    test('a member can reach someone who never invited them', () async {
      // Bob did not add Carol and is not in her address book. Before this she
      // had no way to derive anything with him at all.
      final service = await carolsDevice();

      expect(service.memberExchangeKey(sphereId, bob), bobX);
    });

    test('everyone else in the sphere counts as reachable', () async {
      final service = await carolsDevice();

      expect(service.reachableMembers(sphereId).toSet(), {alice, bob});
    });

    test('we are not in our own list of peers to ask', () async {
      final service = await carolsDevice();

      expect(service.reachableMembers(sphereId), isNot(contains(carol)));
    });

    test('a member with no key recorded is not reachable', () async {
      final service = serviceFor(carol, aliceSecret);
      await service.handleIncomingOp(
        alice,
        signedCreate([
          member(alice, SphereRole.owner, exchange: aliceX),
          member(bob, SphereRole.member), // no key
          member(carol, SphereRole.member, exchange: carolX),
        ]),
      );
      await service.acceptInvite(sphereId);

      expect(service.reachableMembers(sphereId), [alice]);
      expect(service.memberExchangeKey(sphereId, bob), isNull);
    });

    test('the address book wins over the member list', () async {
      // A contact's key came from them. The one in a member list came from
      // whoever wrote the operation, so it is the weaker of the two.
      final service = serviceFor(carol, aliceSecret, known: {bob: 'dd' * 32});
      await service.handleIncomingOp(
        alice,
        signedCreate([
          member(alice, SphereRole.owner, exchange: aliceX),
          member(bob, SphereRole.member, exchange: bobX),
          member(carol, SphereRole.member, exchange: carolX),
        ]),
      );
      await service.acceptInvite(sphereId);

      expect(service.memberExchangeKey(sphereId, bob), 'dd' * 32);
    });

    test('an unknown sphere yields nobody rather than throwing', () {
      final service = serviceFor(carol, aliceSecret);

      expect(service.reachableMembers('f' * 64), isEmpty);
    });
  });

  test('keys cannot be rewritten in flight', () async {
    // They only address transport, but a field an admin could quietly change
    // between devices is not worth leaving unsigned.
    final honest = MembershipOp(
      sphereId: sphereId,
      epoch: 1,
      op: MembershipOp.opCreate,
      target: '',
      by: alice,
      timestampMs: DateTime(2026, 8, 1).millisecondsSinceEpoch,
      members: [
        member(alice, SphereRole.owner, exchange: aliceX),
        member(bob, SphereRole.member, exchange: bobX),
      ],
      name: 'Crew',
      kind: SphereKind.group,
    );
    final signature =
        ed.sign(ed.PrivateKey(hex.decode(aliceSecret)), honest.signedBytes());

    final tampered = MembershipOp(
      sphereId: honest.sphereId,
      epoch: honest.epoch,
      op: honest.op,
      target: honest.target,
      by: honest.by,
      timestampMs: honest.timestampMs,
      members: [
        member(alice, SphereRole.owner, exchange: aliceX),
        // Bob's key swapped for someone else's.
        member(bob, SphereRole.member, exchange: 'ee' * 32),
      ],
      name: honest.name,
      kind: honest.kind,
    );

    final service = serviceFor(carol, aliceSecret);
    await service.handleIncomingOp(
      alice,
      jsonEncode({'op': tampered.toJson(), 'signature': hex.encode(signature)}),
    );

    expect(service.invites, isEmpty);
    expect(service.sphere(sphereId), isNull);
  });
}
