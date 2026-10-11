import 'dart:typed_data';

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

/// Posts gained an author signature, resharing, recommendations, deletion
/// with a trash, and archiving. What is pinned: the signature proves the
/// words and the reshare permission; a reshare of a post whose author said
/// no is refused on receipt; a delete is honoured from the author or an
/// admin and from nobody else; a deleted post can come back within thirty
/// days; one suggestion per person; an archived post leaves the feed only.
void main() {
  late String alice, aliceSecret, bob, bobSecret, carol;
  late SphereService spheres;
  late FeedService feed;
  late Sphere sphere;

  String key(ed.KeyPair k) => hex.encode(k.publicKey.bytes);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    final b = ed.generateKey();
    alice = key(a);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = key(b);
    bobSecret = hex.encode(b.privateKey.bytes);
    carol = key(ed.generateKey());

    spheres = SphereService();
    spheres.configure(
      sessions: SessionManager(),
      identityKey: alice,
      identitySecret: aliceSecret,
      resolveExchangeKey: (_) => null,
    );
    sphere = await spheres.create(
        name: 'Family', kind: SphereKind.group, initialMembers: [bob, carol]);

    feed = FeedService();
    feed.initSync(alice, aliceSecret, const []);
    feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
    feed.membersOf = (id) => spheres.sphere(id)?.members.map((m) => m.identityKey).toList() ?? [];
  });

  Future<void> arrives(String signer, Map<String, dynamic> json) =>
      feed.applyFeedJson(authorId: signer, sphereId: sphere.id, json: json);

  /// A post as Bob would send it: signed with Bob's key.
  Post bobsPost(String id, {bool allowReshare = true, String content = 'hello'}) {
    final p = Post(
      id: id,
      authorId: bob,
      authorName: 'Bob',
      content: content,
      createdAt: DateTime(2026, 10, 11),
      sphereId: sphere.id,
      allowReshare: allowReshare,
    );
    final sig = ed.sign(ed.PrivateKey(hex.decode(bobSecret)),
        Uint8List.fromList(p.signedCore().codeUnits));
    return p.copyWith(authorSig: hex.encode(sig));
  }

  Post current(String id) => feed.posts.singleWhere((p) => p.id == id);

  group('author signature', () {
    test('our own posts are signed and the signature verifies', () async {
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      final p = feed.posts.single;
      expect(p.authorSig, isNotNull);
      expect(FeedService.authorSignatureHolds(p), isTrue);
    });

    test('changing the words breaks it; editing re-signs', () async {
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      final p = feed.posts.single;
      expect(FeedService.authorSignatureHolds(p.copyWith(content: 'forged')), isFalse);
      expect(FeedService.authorSignatureHolds(p.copyWith(allowReshare: false)), isFalse,
          reason: 'the reshare permission is inside the signature');
      await feed.editPost(p.id, 'edited');
      expect(FeedService.authorSignatureHolds(feed.posts.single), isTrue);
    });

    test('an unsigned post from before verifies as false, not as an error', () {
      final old = Post(
          id: 'o', authorId: bob, content: 'x', createdAt: DateTime(2026), sphereId: 's');
      expect(FeedService.authorSignatureHolds(old), isFalse);
      expect(FeedService.authorSignatureHolds(old.copyWith(authorSig: 'zz')), isFalse);
    });
  });

  group('reshare', () {
    test('a reshare carries the original\'s signed words and verifies', () async {
      await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
      final second = await spheres.create(name: 'Work', kind: SphereKind.group, initialMembers: [carol]);
      await feed.resharePost('p1', targets: {second.id}, note: 'look');
      final reshare = feed.posts.singleWhere((p) => p.isReshare);
      expect(reshare.sphereIds, {second.id});
      expect(reshare.content, 'look');
      final original = FeedService.originalOf(reshare)!;
      expect(original.authorId, bob);
      expect(original.content, 'hello');
      expect(FeedService.authorSignatureHolds(original), isTrue);
      expect(FeedService.reshareAllowed(reshare), isTrue);
    });

    test('a post whose author forbade resharing cannot be reshared, and a forged one is refused on receipt',
        () async {
      await arrives(bob, {'type': 'post', 'post': bobsPost('p1', allowReshare: false).toJson()});
      await expectLater(
          feed.resharePost('p1', targets: {sphere.id}), throwsA(isA<StateError>()));

      // Carol strips the flag and reshares anyway: the signature no longer
      // matches the core, so the reshare is dropped.
      final stripped = bobsPost('p1', allowReshare: false).copyWith(allowReshare: true);
      final forged = Post(
        id: 'r1',
        authorId: carol,
        content: '',
        createdAt: DateTime(2026, 10, 12),
        sphereId: sphere.id,
        kind: 'reshare',
        payload: {'original': stripped.toJson()},
      );
      await arrives(carol, {'type': 'post', 'post': forged.toJson()});
      expect(feed.posts.where((p) => p.id == 'r1'), isEmpty);
    });

    test('a reshare of an unsigned original is shown, as the sharer\'s word', () async {
      final unsigned = Post(
          id: 'u', authorId: bob, content: 'old', createdAt: DateTime(2026), sphereId: sphere.id);
      final reshare = Post(
        id: 'r2',
        authorId: carol,
        content: '',
        createdAt: DateTime(2026, 10, 12),
        sphereId: sphere.id,
        kind: 'reshare',
        payload: {'original': unsigned.toJson()},
      );
      await arrives(carol, {'type': 'post', 'post': reshare.toJson()});
      expect(current('r2').isReshare, isTrue);
      expect(FeedService.authorSignatureHolds(FeedService.originalOf(current('r2'))!), isFalse);
    });
  });

  group('delete, trash, archive', () {
    test('a delete from the author or an admin is honoured; from anyone else it is not',
        () async {
      await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
      await arrives(bob, {'type': 'post', 'post': bobsPost('p2').toJson()});
      await arrives(carol, {'type': 'post_delete', 'post_id': 'p1'});
      expect(feed.posts.length, 2, reason: 'Carol is neither');
      await arrives(bob, {'type': 'post_delete', 'post_id': 'p1'});
      expect(feed.posts.map((p) => p.id), ['p2']);
      await arrives(alice, {'type': 'post_delete', 'post_id': 'p2'});
      expect(feed.posts, isEmpty, reason: 'Alice is the admin');
      // Offered back by a sync, it stays gone.
      await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
      expect(feed.posts, isEmpty);
    });

    test('our own deleted post waits in the trash and can be restored', () async {
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      final id = feed.posts.single.id;
      await feed.deletePost(id);
      expect(feed.posts, isEmpty);
      expect(feed.trashedPosts.single.id, id);
      expect(feed.trashedAt(id), isNotNull);

      await feed.restoreFromTrash(id);
      expect(feed.posts.single.id, id);
      expect(feed.trashedPosts, isEmpty);
    });

    test('the trash forgets after thirty days', () async {
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      await feed.deletePost(feed.posts.single.id);
      // Age the entry on disk, then reload.
      final raw = await SecureStore.instance.getString('spheres_post_trash_v1');
      final aged = raw!.replaceAll(
          RegExp(r'"at":"[^"]+"'),
          '"at":"${DateTime.now().subtract(const Duration(days: 31)).toIso8601String()}"');
      await SecureStore.instance.setString('spheres_post_trash_v1', aged);
      final fresh = FeedService();
      fresh.initSync(alice, aliceSecret, const []);
      await fresh.loadPosts();
      expect(fresh.trashedPosts, isEmpty);
    });

    test('archiving hides a post from the feed here and nowhere else', () async {
      await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
      await feed.setArchived('p1', true);
      expect(feed.posts, isEmpty);
      expect(feed.archivedPosts.single.id, 'p1');
      await feed.setArchived('p1', false);
      expect(feed.posts.single.id, 'p1');
    });
  });

  group('recommendations', () {
    test('one suggestion per person, replaced or withdrawn; only on a recommendation post',
        () async {
      final ask = bobsPost('q1').copyWith(
          kind: 'recommend', payload: {'question': 'A dentist?', 'suggestions': {}});
      await arrives(bob, {'type': 'post', 'post': ask.toJson()});
      await arrives(carol, {'type': 'post_suggest', 'post_id': 'q1', 'text': 'Dr A'});
      await arrives(carol, {'type': 'post_suggest', 'post_id': 'q1', 'text': 'Dr B'});
      expect(current('q1').payload!['suggestions'], {carol: 'Dr B'});
      await feed.suggest('q1', 'Dr C');
      expect((current('q1').payload!['suggestions'] as Map).length, 2);
      await arrives(carol, {'type': 'post_suggest', 'post_id': 'q1', 'text': ''});
      expect(current('q1').payload!['suggestions'], {alice: 'Dr C'});

      await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
      await arrives(carol, {'type': 'post_suggest', 'post_id': 'p1', 'text': 'nope'});
      expect(current('p1').payload, isNull, reason: 'not a recommendation post');
    });
  });

  test('malformed new-kind payloads are dropped, never thrown', () async {
    await arrives(bob, {'type': 'post', 'post': bobsPost('p1').toJson()});
    for (final body in <Map<String, dynamic>>[
      {},
      {'post_id': 1},
      {'post_id': 'p1', 'text': 7},
      {'post_id': 'missing', 'text': 'x'},
    ]) {
      await arrives(carol, {'type': 'post_delete', ...body});
      await arrives(carol, {'type': 'post_suggest', ...body});
    }
    await arrives(carol, {
      'type': 'post',
      'post': Post(
        id: 'r9', authorId: carol, content: '', createdAt: DateTime(2026),
        sphereId: sphere.id, kind: 'reshare', payload: {'original': 'not a map'},
      ).toJson(),
    });
    expect(feed.posts.map((p) => p.id), ['p1']);
  });
}
