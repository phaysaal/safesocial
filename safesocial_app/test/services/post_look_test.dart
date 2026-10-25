import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/look.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// A look changed after posting: numbers on the edit path, no new upload,
/// the words and their signature untouched, the author only.
void main() {
  late String alice, aliceSecret, bob, bobSecret;
  late SphereService spheres;
  late FeedService aliceFeed, bobFeed;
  late Sphere family;

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
    spheres = SphereService()
      ..configure(sessions: SessionManager(), identityKey: alice, identitySecret: aliceSecret, resolveExchangeKey: (_) => null);
    family = await spheres.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
    aliceFeed = FeedService();
    aliceFeed.initSync(alice, aliceSecret, const []);
    aliceFeed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
    bobFeed = FeedService();
    bobFeed.initSync(bob, bobSecret, const []);
    bobFeed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
  });

  Post alicesPost() => Post(
        id: 'p1',
        authorId: alice,
        authorName: 'Alice',
        content: 'the lake',
        mediaRefs: const ['data:image/jpeg;base64,AAAA', 'data:image/jpeg;base64,BBBB'],
        createdAt: DateTime(2026, 10, 25),
        sphereId: family.id,
        authorSig: 'sig-1',
      );

  Future<void> bobGets(Map<String, dynamic> json, {String? from}) =>
      bobFeed.applyFeedJson(authorId: from ?? alice, sphereId: family.id, json: json);

  Post bobs() => bobFeed.posts.singleWhere((p) => p.id == 'p1');

  test('the author changes the look and a post_edit of numbers goes to every sphere', () async {
    final sent = <(String, String)>[];
    aliceFeed.onPublished = (s, t) => sent.add((s, t));
    await aliceFeed.createPost('the lake', sphereId: family.id, audienceMembers: [bob],
        mediaRefs: ['data:image/jpeg;base64,AAAA']);
    final id = aliceFeed.posts.single.id;
    final sig = aliceFeed.posts.single.authorSig;
    sent.clear();

    final look = Look.payloadFor([Look.presets.first]);
    await aliceFeed.setPostLook(id, look);
    expect(sent, [(family.id, 'post_edit')]);
    expect(aliceFeed.posts.single.payload?['look'], look);
    expect(aliceFeed.posts.single.editedAt, isNull, reason: 'nothing it says has changed');
    expect(aliceFeed.posts.single.authorSig, sig, reason: 'the words are what is signed');

    await aliceFeed.setPostLook(id, null);
    expect(aliceFeed.posts.single.payload?['look'], isNull);
  });

  test('a reader applies the look, removes it on null, and ignores an edit from a non-author', () async {
    await bobGets({'type': 'post', 'post': alicesPost().toJson()});
    final look = {'*': const Look(exposure: 0.5).toJson()};
    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'look': look, 'sig': 'sig-1'});
    expect(Look.forIndex(bobs().payload, 1).exposure, 0.5);
    expect(bobs().editedAt, isNull);
    expect(bobs().authorSig, 'sig-1');

    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'look': look}, from: bob);
    expect(bobs().payload?['look'], look, reason: 'Bob is not the author');

    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'look': null, 'sig': 'sig-1'});
    expect(bobs().payload?['look'], isNull);
  });

  test('an edit of the words leaves the look; an edit of the look leaves the words and the mark', () async {
    await bobGets({'type': 'post', 'post': alicesPost().toJson()});
    final look = {'*': const Look(temperature: 0.2).toJson()};
    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'look': look, 'sig': 'sig-1'});
    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'content': 'the lake, at dusk', 'edited_at': '2026-10-25T18:00:00Z', 'sig': 'sig-2'});
    expect(bobs().content, 'the lake, at dusk');
    expect(bobs().editedAt, isNotNull);
    expect(bobs().payload?['look'], look, reason: 'an edit not about the look leaves it');
    expect(bobs().authorSig, 'sig-2');
    await bobGets({'type': 'post_edit', 'post_id': 'p1', 'look': null, 'sig': 'sig-2'});
    expect(bobs().content, 'the lake, at dusk');
    expect(bobs().authorSig, 'sig-2', reason: 'a look edit without a sig keeps the one it had');
  });

  test('only the author may change a look here', () async {
    await bobGets({'type': 'post', 'post': alicesPost().toJson()});
    await expectLater(bobFeed.setPostLook('p1', {'*': const Look(exposure: 1).toJson()}), throwsStateError);
  });
}
