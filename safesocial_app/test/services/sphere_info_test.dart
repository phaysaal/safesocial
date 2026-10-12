import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/models/sphere_info.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_info_service.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Sphere governance: one signed item from an admin carries the rules,
/// join questions, topics, welcome line, guides, badges, suspensions and
/// automation; a member keeps the newest from an admin as of the membership
/// it holds and refuses the rest; a suspended member's words are dropped on
/// every device and refused on their own; admins' keyword alerts and the
/// report threshold act from the copy each device holds; invite links carry
/// the questions and retire when the sphere says so.
void main() {
  late String alice, aliceSecret, bob, bobSecret, carol;
  late SphereService spheres;
  late Sphere sphere;
  late SphereInfoService info;
  late List<Map<String, dynamic>> published;

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
    spheres = SphereService();
    spheres.configure(
        sessions: SessionManager(), identityKey: alice, identitySecret: aliceSecret, resolveExchangeKey: (_) => null);
    sphere = await spheres.create(name: 'Crew', kind: SphereKind.group, initialMembers: [bob, carol]);
    info = SphereInfoService(spheres);
    await info.load();
    published = [];
    info.publish = ({required sphereId, required type, required payloadJson}) async =>
        published.add({'sphereId': sphereId, 'type': type, 'json': jsonDecode(payloadJson)});
  });

  test('the model is bounded and round-trips', () {
    final i = SphereInfo.fromJson({
      'sphereId': 's',
      'version': 3,
      'rules': List.filled(30, 'r' * 500),
      'questions': ['a', 'b', 'c', 'd'],
      'topics': ['x', '', 'y'],
      'welcome': 'hi {name}',
      'units': [
        {'id': 'u1', 'title': 't', 'posts': ['p1', 'p2']},
        {'title': 'no id'},
      ],
      'badges': {'m': ['Expert', 'A', 'B', 'C', 'D', 'E', 'F']},
      'suspended': {'m': DateTime(2030).toIso8601String(), 'z': 'junk'},
      'autoMuteReports': 500,
      'inviteDays': -4,
    });
    expect(i.rules, hasLength(20));
    expect(i.rules.first.length, 300);
    expect(i.questions, ['a', 'b', 'c']);
    expect(i.topics, ['x', 'y']);
    expect(i.units.single.postIds, ['p1', 'p2']);
    expect(i.badges['m'], hasLength(5));
    expect(i.suspended.keys, ['m']);
    expect(i.autoMuteReports, 100);
    expect(i.inviteDays, 0);
    expect(SphereInfo.fromJson(i.toJson()), i);
    expect(i.isSuspended('m', now: DateTime(2029)), isTrue);
    expect(i.isSuspended('m', now: DateTime(2031)), isFalse);
  });

  test('an admin publishes a new version; a member keeps the newest from an admin only', () async {
    final v1 = await info.update(sphere.id, (c) => c.copyWith(rules: ['Be kind'], topics: ['Q&A']));
    expect(v1.version, 1);
    expect(v1.by, alice);
    expect(published.single['type'], 'sphere_info');
    expect(info.rulesFor(sphere.id), ['Be kind']);
    expect(info.unseenRules(sphere.id), ['Be kind']);
    await info.markRulesSeen(sphere.id);
    expect(info.unseenRules(sphere.id), isEmpty);

    // Bob's device.
    final bobs = SphereService();
    bobs.configure(sessions: SessionManager(), identityKey: bob, identitySecret: bobSecret, resolveExchangeKey: (_) => null);
    final op = MembershipOp(
      sphereId: sphere.id, epoch: sphere.epoch, op: MembershipOp.opCreate, target: '', by: alice,
      timestampMs: DateTime.now().millisecondsSinceEpoch, members: sphere.members, name: sphere.name, kind: sphere.kind,
    );
    final sig = ed.sign(ed.PrivateKey(hex.decode(aliceSecret)), op.signedBytes());
    await bobs.handleIncomingOp(alice, jsonEncode({'op': op.toJson(), 'signature': hex.encode(sig)}));
    await bobs.acceptInvite(sphere.id);
    final bobInfo = SphereInfoService(bobs);
    await bobInfo.handleIncoming(alice, sphere.id, published.single['json'] as Map<String, dynamic>);
    expect(bobInfo.rulesFor(sphere.id), ['Be kind']);
    expect(bobInfo.unseenRules(sphere.id), ['Be kind'], reason: 'not acknowledged on this device');

    // Carol is no admin; her version is refused. An older version is ignored.
    final forged = v1.copyWith(version: 5, rules: ['Do what Carol says']);
    await bobInfo.handleIncoming(carol, sphere.id, {'type': 'sphere_info', 'info': forged.toJson()});
    expect(bobInfo.rulesFor(sphere.id), ['Be kind']);
    final v2 = await info.update(sphere.id, (c) => c.copyWith(rules: ['Be kind', 'No spam']));
    await bobInfo.handleIncoming(alice, sphere.id, published.last['json'] as Map<String, dynamic>);
    expect(bobInfo.rulesFor(sphere.id), ['Be kind', 'No spam']);
    await bobInfo.handleIncoming(alice, sphere.id, {'type': 'sphere_info', 'info': v1.toJson()});
    expect(bobInfo.infoFor(sphere.id).version, v2.version, reason: 'an old version does not go back');
    expect(bobInfo.unseenRules(sphere.id), hasLength(2), reason: 'changed rules are shown again');

    // Bob cannot publish.
    expect(() => bobInfo.update(sphere.id, (c) => c), throwsStateError);
  });

  test('a suspended member is dropped on receipt and refused on their own device', () async {
    await info.update(sphere.id, (c) => c.copyWith(suspended: {bob: DateTime.now().add(const Duration(days: 1))}));
    expect(info.isSuspended(sphere.id, bob), isTrue);
    expect(info.suspendedUntil(sphere.id, carol), isNull);

    final feed = FeedService();
    feed.initSync(alice, aliceSecret, const []);
    feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
    feed.isSuspended = info.isSuspended;
    Post post(String id, String author) =>
        Post(id: id, authorId: author, content: 'hi', createdAt: DateTime.now(), sphereId: sphere.id);
    await feed.applyFeedJson(authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': post('p1', bob).toJson()});
    await feed.applyFeedJson(authorId: carol, sphereId: sphere.id, json: {'type': 'post', 'post': post('p2', carol).toJson()});
    expect(feed.posts.map((p) => p.id), ['p2']);

    // Bob's own device refuses to post while suspended.
    final bobFeed = FeedService();
    bobFeed.initSync(bob, bobSecret, const []);
    bobFeed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
    bobFeed.isSuspended = (s, m) => m == bob;
    expect(() => bobFeed.createPost('x', sphereId: sphere.id, audienceMembers: const []), throwsStateError);
  });

  test('keyword alerts are local to an admin and only about others', () async {
    info.keywordsFor = (_) => ['for sale', 'crypto'];
    final events = <InboundEvent>[];
    final sub = InboundEvents.stream.listen(events.add);
    expect(info.keywordAlert(sphere.id, bob, 'Bike FOR SALE, cheap', route: '/post/1'), isTrue);
    expect(info.keywordAlert(sphere.id, bob, 'nothing here', route: '/post/2'), isFalse);
    expect(info.keywordAlert(sphere.id, alice, 'my own crypto post', route: '/post/3'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events.single.title, contains('for sale'));
    expect(events.single.from, bob);
    await sub.cancel();
  });

  test('reports mute at the threshold the sphere chose, once', () async {
    var muted = <String>[];
    info.muteLocally = (s, m) async => muted.add(m);
    info.isMutedLocally = (s, m) => muted.contains(m);
    expect(await info.reportsReached(sphere.id, bob, 5), isFalse, reason: 'automation is off');
    await info.update(sphere.id, (c) => c.copyWith(autoMuteReports: 3));
    expect(await info.reportsReached(sphere.id, bob, 2), isFalse);
    expect(await info.reportsReached(sphere.id, bob, 3), isTrue);
    expect(await info.reportsReached(sphere.id, bob, 4), isFalse, reason: 'already muted');
    expect(muted, [bob]);
  });

  test('the invite link carries the questions and retires when it is too old', () async {
    final link = spheres.inviteLink(sphere.id, questions: ['Why?', 'Who told you?']);
    final uri = Uri.parse(link);
    expect(jsonDecode(uri.queryParameters['q']!), ['Why?', 'Who told you?']);
    final token = uri.queryParameters['t'];
    final t0 = spheres.inviteTokenMintedAt(sphere.id)!;
    final same = Uri.parse(spheres.inviteLink(sphere.id, maxAge: const Duration(days: 7), now: t0.add(const Duration(days: 6))));
    expect(same.queryParameters['t'], token);
    final fresh = Uri.parse(spheres.inviteLink(sphere.id, maxAge: const Duration(days: 7), now: t0.add(const Duration(days: 8))));
    expect(fresh.queryParameters['t'], isNot(token));
    expect(await spheres.recordJoinRequest(sphereId: sphere.id, token: token!, requester: {'publicKey': 'x' * 64}), isFalse,
        reason: 'the old token no longer works');
  });

  test('the welcome hook fires after an approval with the newcomer\'s name', () async {
    final joined = <String>[];
    spheres.onMemberJoined = (s, k, name) async => joined.add('$name@$s');
    final link = Uri.parse(spheres.inviteLink(sphere.id));
    final dave = hex.encode(ed.generateKey().publicKey.bytes);
    expect(
        await spheres.recordJoinRequest(
            sphereId: sphere.id, token: link.queryParameters['t']!, requester: {'publicKey': dave, 'name': 'Dave', 'answers': ['because']}),
        isTrue);
    expect(spheres.joinRequestsFor(sphere.id).single['answers'], ['because']);
    await spheres.approveJoin(sphere.id, dave);
    expect(joined, ['Dave@${sphere.id}']);
    expect(spheres.sphere(sphere.id)!.contains(dave), isTrue);
  });
}
