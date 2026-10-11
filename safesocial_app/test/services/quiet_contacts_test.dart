import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/contact.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/profile_about.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/models/user_profile.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/notification_service.dart';
import 'package:spheres_app/services/profile_sharing.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Mute, unfollow, snooze, take a break, restrict, favourite. "Mute this
/// person" and "Unfollow" existed as flags that nothing read; now the feed
/// and the notifications read them. Everything here is local and never told
/// to the other person.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  Contact contact(String key, {DateTime? addedAt}) => Contact(
        publicKey: key,
        displayName: 'Peer $key',
        addedAt: addedAt ?? DateTime(2026),
      );

  group('contact flags', () {
    test('round-trip and the quiet rule', () {
      final c = contact('a').copyWith(
        restricted: true,
        favourite: true,
        onBreak: true,
        snoozedUntil: DateTime(2030),
      );
      final back = Contact.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(back, c);
      expect(back.isQuiet, isTrue);
      expect(contact('b').isQuiet, isFalse);
      expect(contact('c').copyWith(muted: true).isQuiet, isTrue);
    });

    test('a snooze ends by itself; a contact saved before snoozes still reads', () {
      final past = contact('a').copyWith(snoozedUntil: DateTime(2020));
      expect(past.isSnoozed, isFalse);
      expect(past.isQuiet, isFalse);
      final old = Contact.fromJson({'publicKey': 'k', 'displayName': 'K', 'addedAt': '2026-01-01T00:00:00.000'});
      expect(old.restricted, isFalse);
      expect(old.favourite, isFalse);
      expect(old.snoozedUntil, isNull);
    });

    test('a break is quiet and restricted together, and ending it clears both', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      await contacts.addContact('a', 'A', keyExchangePublicKey: 'aa' * 32, announce: false);
      await contacts.setOnBreak('a', true);
      expect(contacts.getContact('a')!.onBreak, isTrue);
      expect(contacts.getContact('a')!.restricted, isTrue);
      expect(contacts.quietKeys(), {'a'});
      await contacts.setOnBreak('a', false);
      expect(contacts.getContact('a')!.restricted, isFalse);
      expect(contacts.quietKeys(), isEmpty);
    });

    test('anniversaries are counted from the day we connected, in earlier years only', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      final now = DateTime.now();
      await contacts.addContact('a', 'A', keyExchangePublicKey: 'aa' * 32, announce: false);
      await contacts.addContact('b', 'B', keyExchangePublicKey: 'bb' * 32, announce: false);
      // addContact stamps today; rewrite one to three years ago today.
      final a = contacts.getContact('a')!;
      await contacts.applyContactSync({
        'op': 'upsert',
        'contact': a.copyWith(addedAt: DateTime(now.year - 3, now.month, now.day)).toJson(),
      });
      final today = contacts.anniversariesToday();
      expect(today.map((e) => (e.$1.publicKey, e.$2)), [('a', 3)],
          reason: 'b was added this year, which is not an anniversary');
    });
  });

  group('the feed', () {
    late String alice, aliceSecret, bob, carol;
    late SphereService spheres;
    late FeedService feed;
    late Sphere sphere;

    setUp(() async {
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
    });

    Post post(String id, String author) => Post(
        id: id, authorId: author, content: id, createdAt: DateTime(2026, 10, 11), sphereId: sphere.id);

    test('a quiet or unfollowed author leaves the feed; our own posts never do', () async {
      var quiet = <String>{};
      var unfollowed = <String>{};
      feed.quietAuthors = () => quiet;
      feed.unfollowedAuthors = () => unfollowed;
      for (final (id, who) in [('b1', bob), ('c1', carol)]) {
        await feed.applyFeedJson(authorId: who, sphereId: sphere.id, json: {'type': 'post', 'post': post(id, who).toJson()});
      }
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      expect(feed.posts.length, 3);

      quiet = {bob};
      expect(feed.posts.map((p) => p.authorId), isNot(contains(bob)));
      unfollowed = {carol, alice};
      expect(feed.posts.map((p) => p.content), ['mine'], reason: 'ours stays whatever the sets say');

      quiet = {};
      unfollowed = {};
      expect(feed.posts.length, 3, reason: 'nothing was deleted, only kept out of view');
    });

    test('with data saver on, a post keeps its unfetched references', () async {
      feed.dataSaver = () => true;
      final p = post('p1', bob).copyWith(mediaRefs: ['spheres-blob:not-fetched']);
      await feed.applyFeedJson(authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': p.toJson()});
      expect(feed.posts.single.mediaRefs, ['spheres-blob:not-fetched']);
    });
  });

  test('a restricted contact gets the name and the picture and nothing else', () {
    final profile = UserProfile(
      publicKey: 'me',
      displayName: 'Fai',
      bio: 'hello',
      updatedAt: DateTime(2026),
      birthday: '10-11',
      about: const ProfileAbout(pronouns: 'he/him'),
    );
    final p = ProfileSharing.payloadFor(
        profile: profile, peer: 'x', sharedSpheres: {'family'}, avatarRef: 'blob:a', restricted: true);
    expect(p.keys.toSet(), {'name', 'avatar'});
    expect(ProfileSharing.visibleFields(profile, {'family'}, restricted: true), isEmpty);
  });

  test('a quiet contact does not notify, except for a call', () async {
    final notifications = NotificationService(sink: _SilentSink());
    await notifications.load();
    notifications.isQuiet = (k) => k == 'quiet';
    InboundEvent event(InboundKind kind, String from) => InboundEvent(
        kind: kind, id: '${kind.name}:$from:${DateTime.now().microsecondsSinceEpoch}', title: 't', body: 'b', route: '/', thread: 't', from: from);
    expect(await notifications.handle(event(InboundKind.chat, 'quiet')), isFalse);
    expect(await notifications.handle(event(InboundKind.chat, 'loud')), isTrue);
    expect(await notifications.handle(event(InboundKind.call, 'quiet')), isTrue);
  });

  test('sphere snooze ends by itself and joins the quiet set', () async {
    final library = LibraryService();
    await library.load();
    await library.snoozeSphere('s1', duration: const Duration(milliseconds: 1));
    await library.snoozeSphere('s2');
    expect(library.isSphereSnoozed('s2'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(library.isSphereSnoozed('s1'), isFalse);
    expect(library.quietSpheres, {'s2'});
    await library.toggleMute('s3');
    expect(library.quietSpheres, {'s2', 's3'});
  });
}

/// A sink that records nothing: the test only asks whether a notification
/// would be shown.
class _SilentSink implements NotificationSink {
  @override
  Future<void> initialize({required void Function(String route) onTap}) async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String thread,
    required String route,
    required bool highPriority,
  }) async {}
  @override
  Future<void> cancelThread(String thread) async {}

  @override
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String route,
  }) async {}
  @override
  Future<void> cancelScheduled(int id) async {}
}
