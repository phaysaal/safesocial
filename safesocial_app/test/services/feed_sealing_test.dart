import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Feed traffic used to go out as plain jsonEncode — posts, likes, reactions
/// and the base64 photos inlined in posts were all readable by the relay, and
/// `author_id` was a self-declared field nothing checked.
///
/// These cover the sealing path the feed now uses.
void main() {
  late String alice;
  late String aliceSecret;
  late String bob;
  late String bobSecret;

  SphereService serviceFor(String id, String secret) {
    final s = SphereService();
    s.configure(
      sessions: SessionManager(),
      identityKey: id,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return s;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final a = ed.generateKey();
    final b = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(b.publicKey.bytes);
    bobSecret = hex.encode(b.privateKey.bytes);
  });

  /// Give Bob the same sphere and epoch key Alice has.
  Future<SphereService> bobSharing(SphereService alices, Sphere sphere) async {
    final bobs = serviceFor(bob, bobSecret);
    // Bob's copy of the membership, as it would arrive via a signed op.
    final op = MembershipOp(
      sphereId: sphere.id,
      epoch: sphere.epoch,
      op: MembershipOp.opCreate,
      target: '',
      by: alice,
      timestampMs: DateTime(2026).millisecondsSinceEpoch,
      members: sphere.members,
      name: sphere.name,
      kind: sphere.kind,
    );
    final signature =
        ed.sign(ed.PrivateKey(hex.decode(aliceSecret)), op.signedBytes());
    await bobs.handleIncomingOp(
      alice,
      jsonEncode({
        'op': op.toJson(),
        'signature': hex.encode(signature),
        'sphereKey':
            base64Encode(alices.keyring.keyFor(sphere.id, sphere.epoch)!),
      }),
    );
    await bobs.acceptInvite(sphere.id);
    return bobs;
  }

  test('a post is unreadable without the sphere key', () async {
    final alices = serviceFor(alice, aliceSecret);
    final sphere = await alices.create(name: 'Family', kind: SphereKind.group);

    final sealed = await alices.sealContent(
      sphereId: sphere.id,
      type: 'post',
      plaintext: jsonEncode({'type': 'post', 'content': 'a private thought'}),
    );

    // What the relay sees.
    expect(sealed.contains('a private thought'), isFalse);
    expect(sealed.contains('private'), isFalse);
  });

  test('a member decrypts it and the author is verified', () async {
    final alices = serviceFor(alice, aliceSecret);
    final sphere = await alices.create(
      name: 'Family',
      kind: SphereKind.group,
      initialMembers: [bob],
    );
    final bobs = await bobSharing(alices, sphere);

    final sealed = await alices.sealContent(
      sphereId: sphere.id,
      type: 'post',
      plaintext: jsonEncode({'type': 'post', 'content': 'hello'}),
    );

    final opened = await bobs.openContent(sealed);

    expect(opened.from, alice);
    expect(opened.sphereId, sphere.id);
    expect(opened.type, 'post');
    expect(jsonDecode(opened.plaintext)['content'], 'hello');
  });

  test('content from someone who left the sphere is refused', () async {
    final alices = serviceFor(alice, aliceSecret);
    final sphere = await alices.create(
      name: 'Family',
      kind: SphereKind.group,
      initialMembers: [bob],
    );
    final bobs = await bobSharing(alices, sphere);

    // Bob seals while still a member.
    final sealed = await bobs.sealContent(
      sphereId: sphere.id,
      type: 'post',
      plaintext: jsonEncode({'type': 'post', 'content': 'still here'}),
    );

    // Alice removes him before it is processed.
    await alices.removeMember(sphere.id, bob);

    await expectLater(alices.openContent(sealed), throwsA(isA<Exception>()));
  });

  test('content for an unknown sphere is refused', () async {
    final alices = serviceFor(alice, aliceSecret);
    final sphere = await alices.create(name: 'Family', kind: SphereKind.group);
    final sealed = await alices.sealContent(
      sphereId: sphere.id,
      type: 'post',
      plaintext: '{}',
    );

    // A device that is not in this sphere at all.
    final stranger = serviceFor(bob, bobSecret);
    await expectLater(stranger.openContent(sealed), throwsA(isA<Exception>()));
  });

  test('a tampered payload does not open', () async {
    final alices = serviceFor(alice, aliceSecret);
    final sphere = await alices.create(name: 'Family', kind: SphereKind.group);
    final sealed = await alices.sealContent(
      sphereId: sphere.id,
      type: 'post',
      plaintext: jsonEncode({'type': 'post', 'content': 'original'}),
    );

    final json = jsonDecode(sealed) as Map<String, dynamic>;
    final ct = base64Decode(json['ct'] as String);
    ct[0] ^= 0x01;
    json['ct'] = base64Encode(ct);

    await expectLater(
      alices.openContent(jsonEncode(json)),
      throwsA(isA<Exception>()),
    );
  });
}
