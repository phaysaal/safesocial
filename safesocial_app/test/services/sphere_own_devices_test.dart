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

/// Found on hardware: Fai's second phone missed the operation that added a
/// member, and from then on refused every later change from Fai's first
/// phone as "a rename may not change the member list". It could never catch
/// up. An operation signed by our own identity on another of our devices is
/// our own decision; it is adopted as it stands.
void main() {
  late String alice, aliceSecret, bob, carol;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    carol = hex.encode(ed.generateKey().publicKey.bytes);
  });

  SphereService serviceFor(String identity, String secret) {
    final s = SphereService();
    s.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return s;
  }

  /// The payload one device sends for its current state of [sphere].
  String opPayload(SphereService from, Sphere sphere, String op, {String target = ''}) {
    final membershipOp = MembershipOp(
      sphereId: sphere.id,
      epoch: sphere.epoch,
      op: op,
      target: target,
      by: alice,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      members: sphere.members,
      name: sphere.name,
      description: sphere.description,
      kind: sphere.kind,
    );
    final signature =
        ed.sign(ed.PrivateKey(hex.decode(aliceSecret)), membershipOp.signedBytes());
    return jsonEncode({
      'op': membershipOp.toJson(),
      'signature': hex.encode(signature),
      'sphereKey': base64Encode(from.keyring.keyFor(sphere.id, sphere.epoch)!),
    });
  }

  test('a sibling device that missed an op adopts a later one from our own identity',
      () async {
    final phone = serviceFor(alice, aliceSecret);
    final tablet = serviceFor(alice, aliceSecret);
    final created = await phone.create(
        name: 'Family', kind: SphereKind.group, initialMembers: [bob]);

    // The tablet learns of the sphere from the create, as it would.
    await tablet.handleIncomingOp(
        alice, opPayload(phone, created, MembershipOp.opCreate));
    await tablet.acceptInvite(created.id);
    expect(tablet.sphere(created.id)!.members.length, 2);

    // The phone adds Carol; that op never reaches the tablet.
    await phone.addMember(created.id, carol);
    // Then renames; this one does.
    await phone.rename(created.id, description: 'carries the key');
    final latest = phone.sphere(created.id)!;
    expect(latest.members.length, 3);

    await tablet.handleIncomingOp(
        alice, opPayload(phone, latest, MembershipOp.opRename));

    final adopted = tablet.sphere(created.id)!;
    expect(adopted.members.length, 3, reason: 'caught up to the member list we signed');
    expect(adopted.epoch, latest.epoch);
    expect(adopted.description, 'carries the key');
    expect(tablet.keyring.keyFor(created.id, latest.epoch), isNotNull,
        reason: 'and holds the key for the epoch it missed');
  });

  test('the same leniency is not extended to another identity', () async {
    final alices = serviceFor(alice, aliceSecret);
    final created = await alices.create(
        name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    // Bob is a member, not an admin; a rename from him is refused as before,
    // and so is one that smuggles in a member.
    final smuggled = created.copyWith(
      epoch: created.epoch + 1,
      members: [...created.members, SphereMember(identityKey: carol, role: SphereRole.member, joinedAt: DateTime.now(), invitedBy: bob)],
    );
    final bobSecret = hex.encode(ed.generateKey().privateKey.bytes);
    final op = MembershipOp(
      sphereId: smuggled.id,
      epoch: smuggled.epoch,
      op: MembershipOp.opRename,
      target: '',
      by: bob,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      members: smuggled.members,
      name: smuggled.name,
      description: smuggled.description,
      kind: smuggled.kind,
    );
    final sig = ed.sign(ed.PrivateKey(hex.decode(bobSecret)), op.signedBytes());
    await alices.handleIncomingOp(
        bob, jsonEncode({'op': op.toJson(), 'signature': hex.encode(sig)}));
    expect(alices.sphere(created.id)!.members.length, 2);
  });
}
