import 'dart:io';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/models/media_provenance.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/models/user_profile.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/media_service.dart';
import 'package:spheres_app/services/profile_sharing.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';
import 'package:spheres_app/widgets/post_extras.dart';

/// Stories: a collage is one picture with the weakest input's origin score,
/// marked as edited; a story hidden from someone is never queued for them;
/// our own stories outlive their day in a local archive; highlights ride the
/// profile under their own audience and only once their pictures are
/// uploaded; link stickers open web links and nothing else.
void main() {
  group('stickers', () {
    test('only web links open', () {
      expect(StorySticker.safeLink('https://example.org/x'), isNotNull);
      expect(StorySticker.safeLink('http://example.org'), isNotNull);
      expect(StorySticker.safeLink('javascript:alert(1)'), isNull);
      expect(StorySticker.safeLink('file:///etc/passwd'), isNull);
      expect(StorySticker.safeLink('intent://scan/#Intent;end'), isNull);
      expect(StorySticker.safeLink('https://'), isNull);
      expect(StorySticker.safeLink(42), isNull);
    });

    test('answers are one line the author can read', () {
      expect(StorySticker.sliderAnswer(73, '🔥'), 'Slider: 73% 🔥');
      expect(StorySticker.quizAnswer('Paris', true), 'Quiz: chose "Paris" (right)');
      expect(StorySticker.quizAnswer('Rome', false), 'Quiz: chose "Rome" (wrong)');
    });
  });

  group('collage', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('spheres_collage_'));
    tearDown(() => tmp.delete(recursive: true));

    Future<String> picture(String name, int w, int h, int score) async {
      final i = img.Image(width: w, height: h);
      img.fill(i, color: img.ColorRgb8(w % 255, h % 255, 50));
      final path = '${tmp.path}/$name.jpg';
      await File(path).writeAsBytes(img.encodeJpg(i));
      await MediaService.writeProvenance(
          path, MediaProvenance(score: score, source: 'gallery', signals: const []));
      return path;
    }

    test('two, three and four pictures become one square', () async {
      final a = await picture('a', 400, 300, 9);
      final b = await picture('b', 300, 500, 6);
      final c = await picture('c', 200, 200, 8);
      final d = await picture('d', 640, 480, 10);
      for (final set in [
        [a, b],
        [a, b, c],
        [a, b, c, d]
      ]) {
        final out = await MediaService.composeCollage(set, into: tmp);
        final decoded = img.decodeImage(await File(out).readAsBytes())!;
        expect(decoded.width, decoded.height, reason: 'square');
        expect(decoded.width, greaterThanOrEqualTo(1000));
      }
    });

    test('the origin score is the weakest input, marked as edited', () async {
      final a = await picture('a', 400, 300, 10);
      final b = await picture('b', 300, 500, 4);
      final out = await MediaService.composeCollage([a, b], into: tmp);
      final p = MediaService.provenanceFor(out)!;
      expect(p.score, 4);
      expect(p.signals, contains('edited_software'));
      final strong = await MediaService.composeCollage([a, await picture('c', 100, 100, 10)], into: tmp);
      expect(MediaService.provenanceFor(strong)!.score, 7, reason: 'an edit caps a camera shot');
    });

    test('one picture is itself; none is refused', () async {
      final a = await picture('a', 400, 300, 9);
      expect(await MediaService.composeCollage([a], into: tmp), a);
      expect(() => MediaService.composeCollage(const [], into: tmp), throwsA(isA<MediaRejectedException>()));
    });
  });

  group('the feed', () {
    late String alice, aliceSecret, bob, carol;
    late SphereService spheres;
    late FeedService feed;
    late Sphere sphere;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await SecureStore.instance.init();
      final a = ed.generateKey();
      alice = hex.encode(a.publicKey.bytes);
      aliceSecret = hex.encode(a.privateKey.bytes);
      bob = hex.encode(ed.generateKey().publicKey.bytes);
      carol = hex.encode(ed.generateKey().publicKey.bytes);
      spheres = SphereService();
      spheres.configure(
        sessions: SessionManager(),
        identityKey: alice,
        identitySecret: aliceSecret,
        resolveExchangeKey: (_) => null,
      );
      sphere = await spheres.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob, carol]);
      feed = FeedService();
      feed.initSync(alice, aliceSecret, const []);
      feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
      await feed.loadPosts();
    });

    test('a story hidden from someone is never queued for them', () async {
      final queued = <String>[];
      feed.onMemberQueued = queued.add;
      await feed.createStory('hi', sphereId: sphere.id, audienceMembers: [bob, carol], hideFrom: {carol});
      expect(queued, contains(bob));
      expect(queued, isNot(contains(carol)));
    });

    test('a story with nobody hidden reaches everyone', () async {
      final queued = <String>[];
      feed.onMemberQueued = queued.add;
      await feed.createStory('hi', sphereId: sphere.id, audienceMembers: [bob, carol]);
      expect(queued, containsAll([bob, carol]));
    });

    test('our own story is kept in the archive without its expiry, across a reload', () async {
      await feed.createStory('day one', sphereId: sphere.id, audienceMembers: [bob]);
      expect(feed.storyArchive, hasLength(1));
      expect(feed.storyArchive.single.content, 'day one');
      expect(feed.storyArchive.single.expiresAt, isNull);
      expect(feed.storyArchive.single.isStory, isTrue);

      final again = FeedService();
      again.initSync(alice, aliceSecret, const []);
      again.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
      await again.loadPosts();
      expect(again.storyArchive.map((p) => p.content), ['day one']);

      await again.removeFromStoryArchive(again.storyArchive.single.id);
      expect(again.storyArchive, isEmpty);
    });

    test('the archive key is sealed at rest', () {
      expect(SecureStore.sensitivePrefixes, contains('spheres_story_archive_v1'));
    });
  });

  group('highlights', () {
    final profile = UserProfile(
      publicKey: 'me',
      displayName: 'Fai',
      bio: '',
      updatedAt: DateTime(2026, 10, 11),
      highlights: const [
        StoryHighlight(id: 'h1', title: 'Summer', refs: ['/local/a.jpg', '/local/b.jpg']),
        StoryHighlight(id: 'h2', title: 'Empty'),
      ],
      audience: {ProfileField.highlights: FieldAudience.spheres({'family'})},
    );

    test('round-trip through json, bounded', () {
      final back = UserProfile.fromJson(profile.toJson());
      expect(back.highlights, profile.highlights);
      final many = StoryHighlight.listFromJson([
        for (var i = 0; i < 30; i++) {'id': 'h$i', 'title': 'x' * 500, 'refs': List.filled(50, 'r')},
        {'title': 'no id'},
        'junk',
      ]);
      expect(many, hasLength(20));
      expect(many.first.title.length, ProfileAbout.shortLimit);
      expect(many.first.refs, hasLength(30));
    });

    test('they travel only to the audience, and only with uploaded pictures', () {
      Map<String, dynamic> send(Set<String> shared, Map<String, List<String>> ups) =>
          ProfileSharing.payloadFor(
              profile: profile, peer: 'p', sharedSpheres: shared, highlightRefs: ups);
      final toFamily = send({'family'}, {'h1': ['blob:a', 'blob:b']});
      expect(toFamily['highlights'], [
        {'id': 'h1', 'title': 'Summer', 'refs': ['blob:a', 'blob:b']}
      ], reason: 'the empty one is left out');
      expect(toFamily['highlights'].toString(), isNot(contains('/local/')));
      expect(send({'work'}, {'h1': ['blob:a']}).containsKey('highlights'), isFalse);
      expect(send({'family'}, const {})['highlights'], isEmpty, reason: 'nothing uploaded, nothing named');
    });

    test('a contact keeps what arrived', () {
      final c = Contact.fromJson({
        'publicKey': 'k',
        'displayName': 'Bo',
        'addedAt': DateTime(2026, 10, 11).toIso8601String(),
        'highlights': [
          {'id': 'h1', 'title': 'Trip', 'refs': ['/x.jpg']}
        ],
      });
      expect(c.highlights.single.title, 'Trip');
      expect(Contact.fromJson(c.toJson()).highlights, c.highlights);
    });

    test('our other devices get relay refs and the local paths stay home', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await SecureStore.instance.init();
      final identity = IdentityService();
      await identity.createIdentity('Fai');
      await identity.addToHighlight(title: 'Summer', ref: '/local/a.jpg');
      final id = identity.currentIdentity!.highlights.single.id;
      await identity.addToHighlight(highlightId: id, ref: '/local/b.jpg');
      await identity.addToHighlight(highlightId: id, ref: '/local/b.jpg');
      expect(identity.currentIdentity!.highlights.single.refs, ['/local/a.jpg', '/local/b.jpg']);
      await identity.addToHighlight(title: '   ', ref: '/local/c.jpg');
      expect(identity.currentIdentity!.highlights, hasLength(1), reason: 'a nameless highlight is not made');

      final out = identity.profileForOwnDevices(highlightRefs: {id: ['blob:a', 'blob:b']});
      expect((out['own'] as Map).containsKey('highlights'), isFalse);
      expect(out['highlights'], [
        {'id': id, 'title': 'Summer', 'refs': ['blob:a', 'blob:b']}
      ]);

      await identity.removeHighlight(id);
      expect(identity.currentIdentity!.highlights, isEmpty);
    });
  });
}
