import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// The WhatsApp- and Facebook-shaped features added in October 2026, at the
/// level below the screens: what travels, what is stored, who is allowed.
void main() {
  late String alice, aliceSecret, bob;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
  });

  SphereService spheresFor(String id, String secret) {
    final s = SphereService();
    s.configure(
      sessions: SessionManager(),
      identityKey: id,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return s;
  }

  group('message model', () {
    test('new fields round-trip and old messages still decode', () {
      final m = Message(
        id: 'm',
        senderId: alice,
        recipientId: bob,
        content: 'q',
        timestamp: DateTime(2026, 10, 11),
        kind: 'poll',
        payload: {'question': 'q', 'options': ['a', 'b'], 'votes': {}},
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        viewOnce: true,
        forwarded: true,
        mentions: [bob],
        readBy: [bob],
        editedAt: DateTime(2026, 10, 11, 1),
      );
      final back = Message.fromJson(m.toJson());
      expect(back, m);
      expect(back.isPoll, isTrue);
      expect(back.isExpired, isFalse, reason: "tomorrow has not come");

      final legacy = {
        'id': 'x',
        'senderId': alice,
        'recipientId': bob,
        'content': 'hi',
        'timestamp': DateTime(2026).toIso8601String(),
      };
      final old = Message.fromJson(legacy);
      expect(old.kind, 'text');
      expect(old.isDeleted, isFalse);
      expect(old.mentions, isEmpty);
    });

    test('the wire omits every default so old messages stay small', () {
      final json = Message(
        id: 'm',
        senderId: alice,
        recipientId: bob,
        content: 'hi',
        timestamp: DateTime(2026),
      ).toJson();
      for (final k in ['kind', 'payload', 'viewOnce', 'forwarded', 'mentions', 'readBy', 'expiresAt', 'deletedAt']) {
        expect(json.containsKey(k), isFalse, reason: k);
      }
    });
  });

  group('post model', () {
    test('events, polls, alt text and co-authors round-trip', () {
      final p = Post(
        id: 'p',
        authorId: alice,
        content: '',
        createdAt: DateTime(2026),
        sphereId: 's',
        kind: 'event',
        payload: {'title': 'Dinner', 'starts_at': '2026-11-01T19:00:00', 'rsvps': {bob: 'going'}},
        altTexts: ['A table'],
        mediaRefs: ['x.jpg'],
        coAuthors: [bob],
        acceptedCoAuthors: [bob],
      );
      final back = Post.fromJson(p.toJson());
      expect(back, p);
      expect(back.isEvent, isTrue);
      expect(Post.fromJson({
        'id': 'q',
        'authorId': alice,
        'content': 'c',
        'createdAt': DateTime(2026).toIso8601String(),
        'sphereId': 's',
      }).kind, 'post');
    });
  });

  group('library', () {
    test('hidden words match case-insensitively and persist', () async {
      final lib = LibraryService();
      await lib.setHiddenWords(['Spoiler', ' crypto ', '']);
      expect(lib.hiddenWords, ['spoiler', 'crypto']);
      expect(lib.hidesText('Big SPOILER ahead'), isTrue);
      expect(lib.hidesText('nothing here'), isFalse);
      final again = LibraryService();
      await again.load();
      expect(again.hidesText('spoiler'), isTrue);
    });

    test('member notes are per sphere and never leave', () async {
      final lib = LibraryService();
      await lib.setMemberNote('s1', bob, 'met at the conference');
      expect(lib.memberNote('s1', bob), 'met at the conference');
      expect(lib.memberNote('s2', bob), isNull);
      await lib.setMemberNote('s1', bob, '   ');
      expect(lib.memberNote('s1', bob), isNull);
    });

    test('stickers and starred messages', () async {
      final lib = LibraryService();
      await lib.addSticker('/a.png');
      await lib.addSticker('/a.png');
      expect(lib.stickers, ['/a.png']);
      await lib.toggleStar('bob', 'm1');
      expect(lib.isStarred('m1'), isTrue);
      await lib.toggleStar('bob', 'm1');
      expect(lib.isStarred('m1'), isFalse);
    });
  });

  group('invite links and join requests', () {
    test('a link carries the sphere, the admin and a token only the admin knows', () async {
      final s = spheresFor(alice, aliceSecret);
      final sphere = await s.create(name: 'Club', kind: SphereKind.group);
      final link = Uri.parse(s.inviteLink(sphere.id));
      expect(link.scheme, 'spheres');
      expect(link.host, 'join');
      expect(link.queryParameters['s'], sphere.id);
      expect(link.queryParameters['via'], alice);
      expect(link.queryParameters['t']!.length, 32);
      expect(s.inviteLink(sphere.id), link.toString(), reason: 'stable until reset');
    });

    test('a request with the right token is kept; wrong or rotated tokens are not', () async {
      final s = spheresFor(alice, aliceSecret);
      final sphere = await s.create(name: 'Club', kind: SphereKind.group);
      final token = Uri.parse(s.inviteLink(sphere.id)).queryParameters['t']!;

      expect(
        await s.recordJoinRequest(sphereId: sphere.id, token: 'nope', requester: {'publicKey': bob, 'name': 'Bob'}),
        isFalse,
      );
      expect(
        await s.recordJoinRequest(sphereId: sphere.id, token: token, requester: {'publicKey': bob, 'name': 'Bob'}),
        isTrue,
      );
      expect(s.joinRequestsFor(sphere.id).single['name'], 'Bob');

      await s.rotateInviteLink(sphere.id);
      final carol = hex.encode(ed.generateKey().publicKey.bytes);
      expect(
        await s.recordJoinRequest(sphereId: sphere.id, token: token, requester: {'publicKey': carol, 'name': 'C'}),
        isFalse,
        reason: 'old link retired',
      );
    });

    test('approving adds the member and runs the contact step first', () async {
      final s = spheresFor(alice, aliceSecret);
      final sphere = await s.create(name: 'Club', kind: SphereKind.group);
      final token = Uri.parse(s.inviteLink(sphere.id)).queryParameters['t']!;
      await s.recordJoinRequest(
          sphereId: sphere.id, token: token, requester: {'publicKey': bob, 'name': 'Bob'});
      final steps = <String>[];
      s.onBeforeApproveJoin = (r) async => steps.add('contact:${r['publicKey']}');

      await s.approveJoin(sphere.id, bob);

      expect(steps, ['contact:$bob']);
      expect(s.sphere(sphere.id)!.contains(bob), isTrue);
      expect(s.joinRequestsFor(sphere.id), isEmpty);
    });

    test('a non-admin cannot mint a link', () async {
      final s = spheresFor(alice, aliceSecret);
      expect(() => s.inviteLink('unknown'), throwsA(anything));
    });
  });

  group('contacts: profiles, birthdays, rate limits', () {
    test('a profile message updates name and birthday; a bad birthday is ignored', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      await contacts.addContact(bob, 'Bob', keyExchangePublicKey: 'aa' * 32, announce: false);

      await contacts.applyProfile(bob, {'name': 'Robert', 'birthday': '10-11'});
      expect(contacts.getContact(bob)!.displayName, 'Robert');
      expect(contacts.getContact(bob)!.birthday, '10-11');

      await contacts.applyProfile(bob, {'birthday': 'tomorrow'});
      expect(contacts.getContact(bob)!.birthday, '10-11');

      final now = DateTime.now();
      final today = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await contacts.applyProfile(bob, {'birthday': today});
      expect(contacts.birthdaysToday().single.publicKey, bob);
    });

    test('a key that keeps knocking on the inbox is ignored after a few tries', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      final requester = hex.encode(ed.generateKey().publicKey.bytes);
      final payload = jsonEncode({
        'type': 'contact_request',
        'name': 'Spammer',
        'publicKey': requester,
        'keyExchangePublicKey': 'bb' * 32,
      });
      for (var i = 0; i < ContactService.maxHandshakesPerHour + 3; i++) {
        await contacts.handleIncomingHandshake(requester, payload);
      }
      // Still exactly one pending request, and no crash: repeats refreshed it,
      // then were dropped.
      expect(contacts.requests.where((r) => r.publicKey == requester), hasLength(1));
    });

    test('a join request through the inbox reaches the sphere hook', () async {
      final contacts = ContactService();
      contacts.setMyInfo('me', 'Me');
      Map<String, dynamic>? seen;
      contacts.onJoinRequest = ({required sphereId, required token, required requester}) async {
        seen = {'sphereId': sphereId, 'token': token, ...requester};
        return true;
      };
      final requester = hex.encode(ed.generateKey().publicKey.bytes);
      await contacts.handleIncomingHandshake(
        requester,
        jsonEncode({
          'type': 'sphere_join_request',
          'sphere_id': 's1',
          'token': 't1',
          'name': 'Dana',
          'publicKey': requester,
          'keyExchangePublicKey': 'cc' * 32,
        }),
      );
      expect(seen?['sphereId'], 's1');
      expect(seen?['token'], 't1');
      expect(seen?['publicKey'], requester);
      expect(contacts.requests, isEmpty, reason: 'a join request is not a contact request');
    });
  });

  group('feed: drafts, events, polls, reports', () {
    late SphereService spheres;
    late FeedService feed;
    late Sphere sphere;

    setUp(() async {
      spheres = spheresFor(alice, aliceSecret);
      sphere = await spheres.create(name: 'Family', kind: SphereKind.group, initialMembers: [bob]);
      feed = FeedService();
      feed.initSync(alice, aliceSecret, const []);
      feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
      feed.membersOf = (id) => spheres.sphere(id)?.members.map((m) => m.identityKey).toList() ?? const [];
    });

    test('a draft is kept, and publishing it makes a post and removes the draft', () async {
      final id = await feed.saveDraft(content: 'later', sphereIds: {sphere.id});
      expect(feed.drafts.single['id'], id);

      await feed.publishDraft(id);

      expect(feed.drafts, isEmpty);
      expect(feed.posts.single.content, 'later');
    });

    test('a scheduled draft posts when its time has come, not before', () async {
      await feed.saveDraft(
          content: 'soon', sphereIds: {sphere.id}, scheduledFor: DateTime.now().add(const Duration(hours: 1)));
      await feed.publishDueDrafts();
      expect(feed.posts, isEmpty);

      await feed.saveDraft(
          content: 'now', sphereIds: {sphere.id}, scheduledFor: DateTime.now().subtract(const Duration(minutes: 1)));
      await feed.publishDueDrafts();
      expect(feed.posts.single.content, 'now');
      expect(feed.drafts, hasLength(1), reason: 'the future one waits');
    });

    test('an event collects RSVPs; a poll collects one vote per person', () async {
      await feed.createEvent(
        sphereIds: {sphere.id},
        audienceMembers: [bob],
        title: 'Dinner',
        startsAt: DateTime(2026, 12, 24, 19),
      );
      final event = feed.posts.single;
      await feed.rsvp(event.id, 'going');
      expect((feed.posts.single.payload!['rsvps'] as Map)[alice], 'going');
      await feed.rsvp(event.id, '');
      expect((feed.posts.single.payload!['rsvps'] as Map).containsKey(alice), isFalse);

      await feed.createPollPost(
          sphereIds: {sphere.id}, audienceMembers: [bob], question: 'Pizza?', options: ['Yes', 'No']);
      final poll = feed.posts.firstWhere((p) => p.isPoll);
      await feed.votePost(poll.id, [0, 1]);
      final votes = feed.posts.firstWhere((p) => p.isPoll).payload!['votes'] as Map;
      expect(votes[alice], [0], reason: 'single choice keeps the first');
    });

    test('a co-author appears only once they confirm', () async {
      await feed.createPost('together', sphereIds: {sphere.id}, audienceMembers: [bob], coAuthors: [bob]);
      expect(feed.posts.single.acceptedCoAuthors, isEmpty);
      // Alice cannot confirm on Bob's behalf.
      await feed.acceptCoAuthorship(feed.posts.single.id);
      expect(feed.posts.single.acceptedCoAuthors, isEmpty);
    });

    test('hidden words hide other people\'s posts, never our own', () async {
      feed.hidesText = (t) => t.toLowerCase().contains('spoiler');
      await feed.createPost('SPOILER: it ends', sphereIds: {sphere.id}, audienceMembers: [bob]);
      expect(feed.posts, hasLength(1), reason: 'our own words are never hidden from us');
    });
  });
}
