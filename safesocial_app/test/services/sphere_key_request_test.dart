import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Found on hardware: the tablet missed two membership changes and could read
/// nothing in the sphere from then on; every post was "No key for epoch 4"
/// and nothing would ever bring the key. Now a member who meets content for
/// an epoch it lacks asks the admins, and an admin answers that member with a
/// signed snapshot of the current state that carries the key.
void main() {
  late String alice, aliceSecret, bob, bobSecret, carol, dave;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    final b = ed.generateKey();
    bob = hex.encode(b.publicKey.bytes);
    bobSecret = hex.encode(b.privateKey.bytes);
    carol = hex.encode(ed.generateKey().publicKey.bytes);
    dave = hex.encode(ed.generateKey().publicKey.bytes);
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

  /// The payload the admin sends for the state of [sphere], with or without
  /// the key.
  String opPayload(SphereService from, Sphere sphere, String op,
      {String target = '', bool withKey = true}) {
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
      if (withKey) 'sphereKey': base64Encode(from.keyring.keyFor(sphere.id, sphere.epoch)!),
    });
  }

  /// Bob joins Alice's sphere at its first epoch and then misses an add and a
  /// rename; two epochs behind, without the key.
  Future<(SphereService, SphereService, Sphere)> bobTwoBehind() async {
    final phone = serviceFor(alice, aliceSecret);
    final bobs = serviceFor(bob, bobSecret);
    final created = await phone.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    await bobs.handleIncomingOp(alice, opPayload(phone, created, MembershipOp.opCreate));
    await bobs.acceptInvite(created.id);
    await phone.addMember(created.id, carol);
    await phone.rename(created.id, description: 'changed while Bob was away');
    final latest = phone.sphere(created.id)!;
    expect(latest.epoch, created.epoch + 2);
    expect(bobs.sphere(created.id)!.epoch, created.epoch);
    expect(bobs.keyring.keyFor(created.id, latest.epoch), isNull);
    return (phone, bobs, latest);
  }

  test('a member who asks is answered with the current state and key, and catches up',
      () async {
    final (phone, bobs, latest) = await bobTwoBehind();
    final request = {'key_request': {'sphereId': latest.id, 'epoch': bobs.sphere(latest.id)!.epoch}};

    final answer = await phone.keyAnswerFor(bob, latest.id, bobs.sphere(latest.id)!.epoch);
    expect(answer, isNotNull);
    final op = MembershipOp.fromJson((jsonDecode(answer!) as Map)['op'] as Map<String, dynamic>);
    expect(op.op, MembershipOp.opSync);
    expect(op.epoch, latest.epoch, reason: 'the epoch we are at, not a new one');

    await bobs.handleIncomingOp(alice, answer);
    final caught = bobs.sphere(latest.id)!;
    expect(caught.epoch, latest.epoch);
    expect(caught.members.map((m) => m.identityKey), containsAll([alice, bob, carol]));
    expect(caught.description, 'changed while Bob was away');
    expect(bobs.keyring.keyFor(latest.id, latest.epoch), isNotNull);
    expect(bobs.eventsFor(latest.id).where((e) => e.op == 'sync'), isEmpty,
        reason: 'an answer is not a change and is not logged');

    // The request itself rides the op channel and is handled there.
    await phone.handleIncomingOp(bob, jsonEncode(request));
  });

  test('the answer goes only to a member, from an admin, who is not behind them', () async {
    final (phone, bobs, latest) = await bobTwoBehind();
    expect(await phone.keyAnswerFor(dave, latest.id, 1), isNull, reason: 'not a member');
    expect(await phone.keyAnswerFor(bob, 'no-such-sphere', 1), isNull);
    expect(await phone.keyAnswerFor(bob, latest.id, latest.epoch + 1), isNull,
        reason: 'they claim to be ahead of us');
    expect(await bobs.keyAnswerFor(carol, latest.id, 1), isNull, reason: 'Bob is no admin');
    expect(await phone.keyAnswerFor(alice, latest.id, 1), isNull, reason: 'not to ourselves');
  });

  test('one member is answered once a minute, and one sphere asked about once in five',
      () async {
    final (phone, bobs, latest) = await bobTwoBehind();
    final t0 = DateTime(2026, 10, 11, 12);
    expect(await phone.keyAnswerFor(bob, latest.id, 1, now: t0), isNotNull);
    expect(await phone.keyAnswerFor(bob, latest.id, 1, now: t0.add(const Duration(seconds: 30))), isNull);
    expect(await phone.keyAnswerFor(bob, latest.id, 1, now: t0.add(const Duration(seconds: 61))), isNotNull);

    final sent = <String>[];
    bobs.sendToPeer = (peer, sealed, {deviceKey}) async {
      sent.add(peer);
      return true;
    };
    // No session with Alice in this test, so nothing is sealed; the throttle
    // and the choice of admins are what is checked.
    expect(await bobs.requestKey(latest.id, now: t0), [alice]);
    expect(await bobs.requestKey(latest.id, now: t0.add(const Duration(minutes: 1))), isEmpty);
    expect(await bobs.requestKey(latest.id, now: t0.add(const Duration(minutes: 6))), [alice]);
  });

  test('a snapshot from someone who is not an admin is refused, and one that is old is ignored',
      () async {
    final (phone, bobs, latest) = await bobTwoBehind();
    final carols = serviceFor(carol, hex.encode(ed.generateKey().privateKey.bytes));
    await carols.handleIncomingOp(alice, opPayload(phone, latest, MembershipOp.opAdd, target: carol));
    await carols.acceptInvite(latest.id);
    expect(carols.sphere(latest.id)!.epoch, latest.epoch);

    // Bob forges a "sync" that drops Carol.
    final forged = MembershipOp(
      sphereId: latest.id,
      epoch: latest.epoch + 1,
      op: MembershipOp.opSync,
      target: carol,
      by: bob,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      members: latest.members.where((m) => m.identityKey != carol).toList(),
      name: latest.name,
      kind: latest.kind,
    );
    final sig = ed.sign(ed.PrivateKey(hex.decode(bobSecret)), forged.signedBytes());
    await carols.handleIncomingOp(bob, jsonEncode({'op': forged.toJson(), 'signature': hex.encode(sig)}));
    expect(carols.sphere(latest.id)!.members.length, 3, reason: 'still a member; Bob is no admin');
    expect(carols.sphere(latest.id)!.epoch, latest.epoch);

    // An answer for an epoch Bob has already passed changes nothing.
    final answer = await phone.keyAnswerFor(bob, latest.id, 1);
    await bobs.handleIncomingOp(alice, answer!);
    final before = bobs.sphere(latest.id)!;
    final stale = jsonDecode(answer) as Map<String, dynamic>;
    (stale['op'] as Map)['epoch'] = before.epoch - 1;
    await bobs.handleIncomingOp(alice, jsonEncode(stale));
    expect(bobs.sphere(latest.id)!.epoch, before.epoch);
  });

  test('a snapshot at our own epoch fills in a missing key and changes nothing else', () async {
    final phone = serviceFor(alice, aliceSecret);
    final bobs = serviceFor(bob, bobSecret);
    final created = await phone.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    // Bob learnt of the sphere without its key.
    await bobs.handleIncomingOp(alice, opPayload(phone, created, MembershipOp.opCreate, withKey: false));
    await bobs.acceptInvite(created.id);
    expect(bobs.keyring.keyFor(created.id, created.epoch), isNull);
    final answer = await phone.keyAnswerFor(bob, created.id, created.epoch);
    await bobs.handleIncomingOp(alice, answer!);
    expect(bobs.keyring.keyFor(created.id, created.epoch), isNotNull);
    expect(bobs.sphere(created.id)!.epoch, created.epoch);
  });

  test('the feed asks for the key when a post arrives for an epoch it lacks', () async {
    final phone = serviceFor(alice, aliceSecret);
    final bobs = serviceFor(bob, bobSecret);
    final created = await phone.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    await bobs.handleIncomingOp(alice, opPayload(phone, created, MembershipOp.opCreate, withKey: false));
    await bobs.acceptInvite(created.id);

    final feed = FeedService();
    feed.initSync(bob, bobSecret, const []);
    feed.attachCrypto(SessionManager(), (_) => null, spheres: bobs);
    final asked = <String>[];
    feed.onMissingKey = (id, epoch) async => asked.add('$id@$epoch');

    final sealed = await phone.sealContent(
        sphereId: created.id, type: 'feed', plaintext: jsonEncode({'type': 'post', 'post': {}}));
    await feed.handleRecovered(alice, sealed);
    expect(asked, ['${created.id}@${created.epoch}']);
  });

  test('the answer carries every key from the epoch they hold to ours, so content from the missed epochs opens too',
      () async {
    final (phone, bobs, latest) = await bobTwoBehind();
    // Something Alice posted during the epoch Bob missed.
    final middle = latest.epoch - 1;
    final sealedInBetween = await phone.sealContent(
        sphereId: latest.id, type: 'feed', plaintext: '{"type":"post"}');
    expect(phone.keyring.keyFor(latest.id, middle), isNotNull, reason: 'an admin keeps old keys');

    final answer = await phone.keyAnswerFor(bob, latest.id, bobs.sphere(latest.id)!.epoch);
    final keys = (jsonDecode(answer!) as Map)['sphereKeys'] as Map;
    expect(keys.keys.map((k) => int.parse('$k')), containsAll([middle, latest.epoch]));

    await bobs.handleIncomingOp(alice, answer);
    expect(bobs.keyring.keyFor(latest.id, middle), isNotNull);
    expect(bobs.keyring.keyFor(latest.id, latest.epoch), isNotNull);
    // Sealed at the current epoch after the catch-up, and at the missed one.
    final opened = await bobs.openContent(sealedInBetween);
    expect(opened.from, alice);
  });

  test('a key from before we joined is never asked for', () async {
    final phone = serviceFor(alice, aliceSecret);
    final created = await phone.create(name: 'Family', kind: SphereKind.group, initialMembers: [carol]);
    await phone.rename(created.id, description: 'before Bob');
    final old = await phone.sealContent(sphereId: created.id, type: 'feed', plaintext: '{"type":"post"}');
    await phone.addMember(created.id, bob);
    final latest = phone.sphere(created.id)!;

    final bobs = serviceFor(bob, bobSecret);
    await bobs.handleIncomingOp(alice, opPayload(phone, latest, MembershipOp.opAdd, target: bob));
    await bobs.acceptInvite(created.id);
    expect(bobs.keyring.earliestEpoch(created.id), latest.epoch);
    final sent = <String>[];
    bobs.sendToPeer = (peer, sealed, {deviceKey}) async {
      sent.add(peer);
      return true;
    };
    final oldEpoch = Envelope.decode(old).sphereEpoch;
    expect(oldEpoch, lessThan(latest.epoch));
    expect(await bobs.requestKey(created.id, epoch: oldEpoch), isEmpty,
        reason: 'sealed before Bob was a member; not his to read');
    expect(await bobs.requestKey(created.id, epoch: latest.epoch), isEmpty,
        reason: 'he already holds it');
    expect(await bobs.requestKey(created.id, epoch: latest.epoch + 1), [alice]);
  });
}
