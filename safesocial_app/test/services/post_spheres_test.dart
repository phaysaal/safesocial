import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// A post's spheres can change after it was sent. The author's device sends
/// the post to a sphere added and a delete scoped to a sphere removed; a
/// reader in two of its spheres keeps it in the one it stays in, a reader in
/// the removed one alone loses it, and a sync round offering the removed
/// copy back does not put it back.
void main() {
  late String alice, aliceSecret, bob, bobSecret;
  late SphereService aliceSpheres, bobSpheres;
  late FeedService aliceFeed, bobFeed;
  late Sphere family, work;

  String key(ed.KeyPair k) => hex.encode(k.publicKey.bytes);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey(), b = ed.generateKey();
    alice = key(a);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = key(b);
    bobSecret = hex.encode(b.privateKey.bytes);

    aliceSpheres = SphereService()
      ..configure(
          sessions: SessionManager(),
          identityKey: alice,
          identitySecret: aliceSecret,
          resolveExchangeKey: (_) => null);
    family = await aliceSpheres.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    work = await aliceSpheres.create(name: 'Work', kind: SphereKind.group, initialMembers: [bob]);

    aliceFeed = FeedService();
    aliceFeed.initSync(alice, aliceSecret, const []);
    aliceFeed.attachCrypto(SessionManager(), (_) => null, spheres: aliceSpheres);

    // Bob's view: the same member lists (what matters here is who signed and
    // who is an admin where), his own feed and keys.
    bobSpheres = aliceSpheres;
    bobFeed = FeedService();
    bobFeed.initSync(bob, bobSecret, const []);
    bobFeed.attachCrypto(SessionManager(), (_) => null, spheres: bobSpheres);
  });

  Post post(Set<String> spheres) => Post(
        id: 'p1',
        authorId: alice,
        authorName: 'Alice',
        content: 'hello',
        createdAt: DateTime(2026, 10, 16),
        sphereId: spheres.first,
        sphereIds: spheres,
      );

  Future<void> bobGets(String viaSphere, Map<String, dynamic> json) =>
      bobFeed.applyFeedJson(authorId: alice, sphereId: viaSphere, json: json);

  Post? bobsCopy() => bobFeed.posts.where((p) => p.id == 'p1').firstOrNull;

  group('the author', () {
    test('adding a sphere sends the post there; removing one sends a scoped delete', () async {
      final sent = <(String, String)>[];
      // What leaves is sealed per sphere; the test reads what was sealed.
      aliceFeed.onPublished = (sphereId, type) => sent.add((sphereId, type));

      await aliceFeed.createPost('hello', sphereId: family.id, audienceMembers: [bob]);
      final id = aliceFeed.posts.single.id;
      sent.clear();

      await aliceFeed.setPostSpheres(id, {family.id, work.id});
      expect(aliceFeed.posts.single.sphereIds, {family.id, work.id});
      expect(sent, [(work.id, 'post')]);

      sent.clear();
      await aliceFeed.setPostSpheres(id, {work.id});
      expect(aliceFeed.posts.single.sphereIds, {work.id});
      expect(aliceFeed.posts.single.sphereId, work.id, reason: 'the primary moves with it');
      expect(sent, [(family.id, 'post_delete')]);
    });

    test('a post cannot be left with no sphere, and only the author moves it', () async {
      await aliceFeed.createPost('hello', sphereId: family.id, audienceMembers: [bob]);
      final id = aliceFeed.posts.single.id;
      await expectLater(aliceFeed.setPostSpheres(id, {}), throwsStateError);
      await expectLater(aliceFeed.setPostSpheres(id, {'nope'}), throwsStateError);
      // Bob holds Alice's post; he may not move it.
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await expectLater(bobFeed.setPostSpheres('p1', {work.id}), throwsStateError);
    });
  });

  group('a reader', () {
    test('in both spheres keeps the post where it stays', () async {
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await bobGets(work.id, {'type': 'post', 'post': post({work.id}).toJson()});
      expect(bobsCopy()!.sphereIds, {family.id, work.id});

      await bobGets(family.id, {'type': 'post_delete', 'post_id': 'p1', 'sphere_id': family.id});
      expect(bobsCopy()!.sphereIds, {work.id});
      expect(bobsCopy()!.sphereId, work.id);
    });

    test('in the removed sphere alone loses it', () async {
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await bobGets(family.id, {'type': 'post_delete', 'post_id': 'p1', 'sphere_id': family.id});
      expect(bobsCopy(), isNull);
    });

    test('is not given the removed copy back by a sync round', () async {
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await bobGets(work.id, {'type': 'post', 'post': post({work.id}).toJson()});
      await bobGets(family.id, {'type': 'post_delete', 'post_id': 'p1', 'sphere_id': family.id});

      // A peer in Family offers the old copy again.
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      expect(bobsCopy()!.sphereIds, {work.id});

      // And after a restart the memory holds.
      final again = FeedService();
      again.initSync(bob, bobSecret, const []);
      again.attachCrypto(SessionManager(), (_) => null, spheres: bobSpheres);
      await again.loadPosts();
      await again.applyFeedJson(authorId: alice, sphereId: family.id, json: {'type': 'post', 'post': post({family.id}).toJson()});
      expect(again.posts.singleWhere((p) => p.id == 'p1').sphereIds, {work.id});
    });

    test('a scoped delete from someone who is neither author nor admin there is dropped', () async {
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await bobFeed.applyFeedJson(
          authorId: bob, sphereId: family.id,
          json: {'type': 'post_delete', 'post_id': 'p1', 'sphere_id': family.id});
      expect(bobsCopy(), isNotNull);
    });

    test('an unscoped delete, from a client before this, still drops the whole post', () async {
      await bobGets(family.id, {'type': 'post', 'post': post({family.id}).toJson()});
      await bobGets(work.id, {'type': 'post', 'post': post({work.id}).toJson()});
      await bobGets(family.id, {'type': 'post_delete', 'post_id': 'p1'});
      expect(bobsCopy(), isNull);
    });
  });
}
