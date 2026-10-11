import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/event_time.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/event_reminders.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/notification_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Events: when a repeating one happens next, what a calendar file says,
/// who may change the details (the author and the co-hosts they named),
/// that anyone in the sphere may add a picture once, and that reminders are
/// scheduled for what is ahead and cancelled for what is not.
void main() {
  group('EventTime', () {
    final now = DateTime(2026, 10, 11, 12);

    test('a one-off event is its own occurrence, past or not', () {
      final past = DateTime(2026, 10, 1, 9);
      final o = EventTime.occurrence(starts: past, now: now);
      expect(o.starts, past);
      expect(EventTime.isPast(starts: past, now: now), isTrue);
      expect(EventTime.isPast(starts: DateTime(2026, 12, 1), now: now), isFalse);
    });

    test('a weekly event steps to the first occurrence not yet over, keeping its length',
        () {
      final starts = DateTime(2026, 9, 1, 18);
      final ends = DateTime(2026, 9, 1, 20);
      final o = EventTime.occurrence(starts: starts, ends: ends, recurrence: 'weekly', now: now);
      expect(o.starts, DateTime(2026, 10, 13, 18), reason: 'Tuesdays; the 13th is next');
      expect(o.ends, DateTime(2026, 10, 13, 20));
      expect(EventTime.isPast(starts: starts, ends: ends, recurrence: 'weekly', now: now), isFalse);
    });

    test('an occurrence under way is the current one', () {
      final starts = DateTime(2026, 10, 11, 11);
      final ends = DateTime(2026, 10, 11, 13);
      final o = EventTime.occurrence(starts: starts, ends: ends, recurrence: 'daily', now: now);
      expect(o.starts, starts);
    });

    test('monthly and yearly step by calendar units', () {
      final starts = DateTime(2026, 1, 15, 9);
      expect(EventTime.occurrence(starts: starts, recurrence: 'monthly', now: now).starts,
          DateTime(2026, 10, 15, 9));
      expect(EventTime.occurrence(starts: starts, recurrence: 'yearly', now: now).starts,
          DateTime(2027, 1, 15, 9));
    });

    test('an unknown recurrence is treated as none', () {
      final past = DateTime(2026, 1, 1);
      expect(EventTime.occurrence(starts: past, recurrence: 'fortnightly', now: now).starts, past);
      expect(EventTime.isPast(starts: past, recurrence: 'fortnightly', now: now), isTrue);
    });

    test('the calendar file has what a calendar needs and escapes what it must', () {
      final ics = EventTime.ics(
        uid: 'p1@spheres',
        title: 'Dinner; with, friends',
        starts: DateTime.utc(2026, 10, 20, 18),
        ends: DateTime.utc(2026, 10, 20, 21),
        place: 'Paris',
        description: 'line one\nline two',
        recurrence: 'weekly',
        url: 'https://tickets.example',
      );
      expect(ics, contains('BEGIN:VEVENT'));
      expect(ics, contains('DTSTART:20261020T180000Z'));
      expect(ics, contains('DTEND:20261020T210000Z'));
      expect(ics, contains(r'SUMMARY:Dinner\; with\, friends'));
      expect(ics, contains(r'DESCRIPTION:line one\nline two'));
      expect(ics, contains('RRULE:FREQ=WEEKLY'));
      expect(ics, contains('URL:https://tickets.example'));
      expect(ics.split('\r\n').last, '', reason: 'CRLF line ends');
    });
  });

  group('the feed', () {
    late String alice, aliceSecret, bob, carol, dave;
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
      dave = hex.encode(ed.generateKey().publicKey.bytes);
      spheres = SphereService();
      spheres.configure(
        sessions: SessionManager(),
        identityKey: alice,
        identitySecret: aliceSecret,
        resolveExchangeKey: (_) => null,
      );
      sphere = await spheres.create(
          name: 'Family', kind: SphereKind.group, initialMembers: [bob, carol, dave]);
      feed = FeedService();
      feed.initSync(alice, aliceSecret, const []);
      feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
    });

    Future<void> arrives(String signer, Map<String, dynamic> json) =>
        feed.applyFeedJson(authorId: signer, sphereId: sphere.id, json: json);

    Post event(String id, String author, {List<String> coHosts = const []}) => Post(
          id: id,
          authorId: author,
          content: 'details',
          createdAt: DateTime(2026, 10, 11),
          sphereId: sphere.id,
          kind: 'event',
          payload: {
            'title': 'Dinner',
            'starts_at': DateTime(2026, 12, 1, 19).toIso8601String(),
            'place': 'Paris',
            'rsvps': <String, dynamic>{},
            if (coHosts.isNotEmpty) 'co_hosts': coHosts,
            'photos': <dynamic>[],
          },
        );

    Post current(String id) => feed.posts.singleWhere((p) => p.id == id);

    test('interested is an answer', () async {
      await arrives(bob, {'type': 'post', 'post': event('e1', bob).toJson()});
      await arrives(carol, {'type': 'event_rsvp', 'post_id': 'e1', 'status': 'interested'});
      expect(current('e1').payload!['rsvps'], {carol: 'interested'});
      await arrives(carol, {'type': 'event_rsvp', 'post_id': 'e1', 'status': 'keen'});
      expect(current('e1').payload!['rsvps'], {carol: 'interested'}, reason: 'not a status');
    });

    test('the author and a co-host may change the details; nobody else; co-hosts only the author',
        () async {
      await arrives(bob, {'type': 'post', 'post': event('e1', bob, coHosts: [carol]).toJson()});
      expect(FeedService.hostedBy(current('e1'), carol), isTrue);
      expect(FeedService.hostedBy(current('e1'), dave), isFalse);

      await arrives(dave, {'type': 'event_update', 'post_id': 'e1', 'place': 'Lyon'});
      expect(current('e1').payload!['place'], 'Paris');

      await arrives(carol, {'type': 'event_update', 'post_id': 'e1', 'place': 'Lyon', 'recurrence': 'weekly'});
      expect(current('e1').payload!['place'], 'Lyon');
      expect(current('e1').payload!['recurrence'], 'weekly');

      await arrives(carol, {'type': 'event_update', 'post_id': 'e1', 'co_hosts': [carol, dave]});
      expect(current('e1').payload!['co_hosts'], [carol], reason: 'only the author names co-hosts');
      await arrives(bob, {'type': 'event_update', 'post_id': 'e1', 'co_hosts': [dave]});
      expect(current('e1').payload!['co_hosts'], [dave]);

      await arrives(bob, {'type': 'event_update', 'post_id': 'e1', 'title': '', 'starts_at': 'yesterday', 'recurrence': 'fortnightly'});
      expect(current('e1').payload!['title'], 'Dinner', reason: 'a title and a start cannot be cleared');
      expect(current('e1').payload!['recurrence'], 'weekly', reason: 'an unknown recurrence is ignored');
    });

    test('anyone in the sphere adds a picture, once per picture', () async {
      await arrives(bob, {'type': 'post', 'post': event('e1', bob).toJson()});
      await arrives(dave, {'type': 'event_photo', 'post_id': 'e1', 'id': 'ph1', 'ref': '/local/one.jpg', 'caption': 'us'});
      await arrives(dave, {'type': 'event_photo', 'post_id': 'e1', 'id': 'ph1', 'ref': '/local/one.jpg'});
      await arrives(carol, {'type': 'event_photo', 'post_id': 'e1', 'id': 'ph2', 'ref': '/local/two.jpg'});
      final photos = current('e1').payload!['photos'] as List;
      expect(photos.length, 2);
      expect(photos.first['by'], dave);
      expect(photos.first['caption'], 'us');
      // Malformed ones are dropped.
      await arrives(carol, {'type': 'event_photo', 'post_id': 'e1', 'id': 7, 'ref': '/x'});
      await arrives(carol, {'type': 'event_photo', 'post_id': 'e1', 'id': 'ph3'});
      expect((current('e1').payload!['photos'] as List).length, 2);
    });

    test('upcoming events are the ones not over, soonest first, recurring by next occurrence',
        () async {
      final past = event('old', bob).copyWith(payload: {
        ...event('old', bob).payload!,
        'starts_at': DateTime(2020, 1, 1).toIso8601String(),
      });
      final weekly = event('weekly', bob).copyWith(payload: {
        ...event('weekly', bob).payload!,
        'starts_at': DateTime(2020, 1, 1, 8).toIso8601String(),
        'recurrence': 'weekly',
      });
      for (final p in [past, weekly, event('dec', bob)]) {
        await arrives(bob, {'type': 'post', 'post': p.toJson()});
      }
      final ids = feed.upcomingEvents.map((p) => p.id).toList();
      expect(ids, ['weekly', 'dec'], reason: 'the weekly one is within a week; December is later');
    });
  });

  group('reminders', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await SecureStore.instance.init();
    });

    test('chosen offsets ahead of now are scheduled; the rest are cancelled; the choice persists',
        () async {
      final sink = _RecordingSink();
      final notifications = NotificationService(sink: sink);
      await notifications.load();
      final library = LibraryService();
      await library.load();
      final post = Post(
        id: 'e1',
        authorId: 'bob',
        content: '',
        createdAt: DateTime.now(),
        sphereId: 's',
        kind: 'event',
        payload: {
          'title': 'Soon',
          'starts_at': DateTime.now().add(const Duration(hours: 2)).toIso8601String(),
        },
      );
      await EventReminders.set(
          post: post, minutesBefore: [15, 60, 1440], library: library, notifications: notifications);
      expect(library.eventReminders('e1'), [15, 60, 1440]);
      expect(sink.scheduled.keys, {15, 60}.map((m) => EventReminders.notificationId('e1', m)).toSet(),
          reason: 'a day before is already in the past');
      expect(sink.cancelled, containsAll([EventReminders.notificationId('e1', 1440), EventReminders.notificationId('e1', 10080)]));
      expect(sink.scheduled[EventReminders.notificationId('e1', 60)]!.route, '/post/e1');

      await EventReminders.set(post: post, minutesBefore: const [], library: library, notifications: notifications);
      expect(library.eventReminders('e1'), isEmpty);
      expect(sink.cancelled, contains(EventReminders.notificationId('e1', 15)));
    });
  });
}

class _Scheduled {
  final DateTime at;
  final String route;
  _Scheduled(this.at, this.route);
}

class _RecordingSink implements NotificationSink {
  final scheduled = <int, _Scheduled>{};
  final cancelled = <int>[];
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
  }) async {
    scheduled[id] = _Scheduled(at, route);
  }

  @override
  Future<void> cancelScheduled(int id) async => cancelled.add(id);
}
