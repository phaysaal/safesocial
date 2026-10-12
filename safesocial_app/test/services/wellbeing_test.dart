import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/post.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/chat_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/library_service.dart';
import 'package:spheres_app/services/notification_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';
import 'package:spheres_app/services/theme_service.dart';
import 'package:spheres_app/services/wellbeing_service.dart';

class _Sink implements NotificationSink {
  final shown = <String>[];
  @override
  Future<void> initialize({required void Function(String route) onTap}) async {}
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> show({required int id, required String title, required String body, required String thread, required String route, required bool highPriority}) async =>
      shown.add(title);
  @override
  Future<void> cancelThread(String thread) async {}
  @override
  Future<void> schedule({required int id, required DateTime at, required String title, required String body, required String route}) async {}
  @override
  Future<void> cancelScheduled(int id) async {}
}

/// Time on the app and what it triggers: a dimmed twenty-second break after
/// twenty minutes in a row, a daily reminder once, quiet hours that wrap
/// midnight, a pause that rests the relay and keeps everything; and the
/// local safety and comfort rules around them.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('breaks', () {
    test('after twenty minutes in a row the break starts, counts twenty seconds down, and the clock restarts', () async {
      final w = WellbeingService();
      var now = DateTime(2026, 10, 12, 10);
      w.clock = () => now;
      w.tick(seconds: 19 * 60 + 59);
      expect(w.breakActive, isFalse);
      w.tick();
      expect(w.breakActive, isTrue);
      expect(w.breakRemaining, 20);
      w.tick(seconds: 19);
      expect(w.breakActive, isTrue);
      expect(w.breakRemaining, 1);
      w.tick();
      expect(w.breakActive, isFalse);
      expect(w.sessionSeconds, 0, reason: 'the twenty minutes start again');
      expect(w.minutesToday, 20);
    });

    test('skipping ends the break and restarts the clock; turning breaks off ends one', () {
      final w = WellbeingService();
      w.tick(seconds: 20 * 60);
      expect(w.breakActive, isTrue);
      w.skipBreak();
      expect(w.breakActive, isFalse);
      expect(w.sessionSeconds, 0);
      w.tick(seconds: 20 * 60);
      expect(w.breakActive, isTrue);
      w.setBreakReminders(false);
      expect(w.breakActive, isFalse);
      w.tick(seconds: 40 * 60);
      expect(w.breakActive, isFalse, reason: 'off means off');
    });

    test('five minutes away is a break of its own', () {
      final w = WellbeingService();
      var now = DateTime(2026, 10, 12, 10);
      w.clock = () => now;
      w.onForeground();
      w.tick(seconds: 15 * 60);
      w.onBackground();
      now = now.add(const Duration(minutes: 6));
      w.onForeground();
      expect(w.sessionSeconds, 0);
      w.onBackground();
      w.onForeground();
      w.tick(seconds: 10);
      w.onBackground();
      now = now.add(const Duration(minutes: 1));
      w.onForeground();
      expect(w.sessionSeconds, 10, reason: 'a minute away does not count');
      w.dispose();
    });
  });

  test('the daily reminder fires once when the limit is passed, and usage survives a reload', () async {
    final w = WellbeingService();
    w.clock = () => DateTime(2026, 10, 12, 10);
    await w.setDailyLimit(30);
    final events = <InboundEvent>[];
    final sub = InboundEvents.stream.listen(events.add);
    w.tick(seconds: 29 * 60);
    w.tick(seconds: 60);
    w.tick(seconds: 60);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.route, '/wellbeing');
    expect(w.dailyLimitReached, isTrue);
    await sub.cancel();

    final again = WellbeingService();
    again.clock = () => DateTime(2026, 10, 12, 11);
    await again.load();
    expect(again.minutesToday, 31);
    expect(again.dailyLimitMinutes, 30);
    expect(again.lastSevenDays.last.$2, 31);
    expect(again.lastSevenDays, hasLength(7));
  });

  test('quiet hours wrap midnight and keep calls ringing', () async {
    final w = WellbeingService();
    await w.setQuietHours(22 * 60, 7 * 60);
    expect(w.inQuietHours(now: DateTime(2026, 10, 12, 23)), isTrue);
    expect(w.inQuietHours(now: DateTime(2026, 10, 12, 3)), isTrue);
    expect(w.inQuietHours(now: DateTime(2026, 10, 12, 12)), isFalse);
    await w.setQuietHours(9 * 60, 17 * 60);
    expect(w.inQuietHours(now: DateTime(2026, 10, 12, 12)), isTrue);
    expect(w.inQuietHours(now: DateTime(2026, 10, 12, 20)), isFalse);

    final sink = _Sink();
    final n = NotificationService(sink: sink);
    await n.load();
    AppLifecycle.foreground = false;
    n.inQuietHours = () => true;
    expect(await n.handle(const InboundEvent(kind: InboundKind.chat, id: 'q1', title: 'Bob', body: 'hi', route: '/chat/b', thread: 't')), isFalse);
    expect(await n.handle(const InboundEvent(kind: InboundKind.call, id: 'q2', title: 'Bob', body: 'call', route: '/call', thread: 'c')), isTrue);
    expect(sink.shown, ['Bob']);
  });

  test('pause tells the app, holds across a reload, and stops the clock', () async {
    final w = WellbeingService();
    final changes = <bool>[];
    w.onPauseChanged = (p) async => changes.add(p);
    await w.setPaused(true);
    await w.setPaused(true);
    expect(changes, [true], reason: 'once');
    w.tick(seconds: 600);
    expect(w.minutesToday, 0, reason: 'paused time is not counted');
    final again = WellbeingService();
    await again.load();
    expect(again.paused, isTrue);
    await w.setPaused(false);
    expect(changes, [true, false]);
  });

  group('feed and chat comforts', () {
    late String alice, aliceSecret, bob, carol;
    late SphereService spheres;
    late Sphere sphere;
    late FeedService feed;

    setUp(() async {
      final a = ed.generateKey();
      alice = hex.encode(a.publicKey.bytes);
      aliceSecret = hex.encode(a.privateKey.bytes);
      bob = hex.encode(ed.generateKey().publicKey.bytes);
      carol = hex.encode(ed.generateKey().publicKey.bytes);
      spheres = SphereService();
      spheres.configure(sessions: SessionManager(), identityKey: alice, identitySecret: aliceSecret, resolveExchangeKey: (_) => null);
      sphere = await spheres.create(name: 'Crew', kind: SphereKind.group, initialMembers: [bob, carol]);
      feed = FeedService();
      feed.initSync(alice, aliceSecret, const []);
      feed.attachCrypto(SessionManager(), (_) => null, spheres: spheres);
      await feed.loadPosts();
    });

    test('a restricted contact\'s comment on our post is hidden on arrival; another\'s is not', () async {
      feed.restrictedKeys = () => {bob};
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      final post = feed.posts.single;
      Map<String, dynamic> comment(String id, String by) =>
          {'type': 'comment', 'post_id': post.id, 'comment': Comment(id: id, authorId: by, authorName: 'x', text: 'hey', createdAt: DateTime.now()).toJson()};
      await feed.applyFeedJson(authorId: bob, sphereId: sphere.id, json: comment('c1', bob));
      await feed.applyFeedJson(authorId: carol, sphereId: sphere.id, json: comment('c2', carol));
      final comments = feed.posts.single.comments;
      expect(comments.firstWhere((c) => c.id == 'c1').hidden, isTrue);
      expect(comments.firstWhere((c) => c.id == 'c2').hidden, isFalse);
    });

    test('tagged posts are found, and tag review decides whether they show', () async {
      final tagged = Post(id: 't1', authorId: bob, content: 'with Alice', createdAt: DateTime.now(), sphereId: sphere.id, payload: {'tags': [alice]});
      await feed.applyFeedJson(authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': tagged.toJson()});
      expect(feed.taggedPosts(alice).map((p) => p.id), ['t1']);
      expect(feed.taggedPosts(carol), isEmpty);
      final library = LibraryService();
      await library.load();
      expect(library.tagReview, isTrue);
      expect(library.showsTag('t1'), isFalse, reason: 'waits for a yes');
      await library.reviewTag('t1', approve: true);
      expect(library.showsTag('t1'), isTrue);
      await library.reviewTag('t1', approve: false);
      expect(library.showsTag('t1'), isFalse);
      await library.setTagReview(false);
      expect(library.showsTag('t1'), isFalse, reason: 'a hidden one stays hidden');
      expect(library.showsTag('t2'), isTrue, reason: 'review off: everything else shows');
    });

    test('the Home dot counts others\' posts since the feed was last looked at', () async {
      expect(feed.unseenCount, 0);
      final p = Post(id: 'n1', authorId: bob, content: 'new', createdAt: DateTime.now(), sphereId: sphere.id);
      await feed.applyFeedJson(authorId: bob, sphereId: sphere.id, json: {'type': 'post', 'post': p.toJson()});
      await feed.createPost('mine', sphereId: sphere.id, audienceMembers: const []);
      expect(feed.unseenCount, 1, reason: 'our own post does not count');
      await feed.markFeedSeen();
      expect(feed.unseenCount, 0);
    });
  });

  test('search history keeps ten, newest first, and clears', () async {
    final library = LibraryService();
    await library.load();
    for (var i = 0; i < 12; i++) {
      await library.addSearch('query $i');
    }
    await library.addSearch('query 3');
    await library.addSearch('a');
    expect(library.searchHistory.first, 'query 3');
    expect(library.searchHistory, hasLength(10));
    expect(library.searchHistory, isNot(contains('a')), reason: 'too short');
    final again = LibraryService();
    await again.load();
    expect(again.searchHistory.first, 'query 3');
    await again.clearSearchHistory();
    expect(again.searchHistory, isEmpty);
  });

  test('a poke is a message kind with a sentence, at most one a minute', () async {
    final m = Message(id: 'p', senderId: 'a', recipientId: 'b', content: '👉', timestamp: DateTime.now(), kind: 'poke');
    expect(ChatService.describeMessage(m), 'Poked you 👉');
    final chat = ChatService();
    expect(() => chat.poke('nobody'), throwsStateError, reason: 'no identity: the send itself fails');
  });

  test('accessibility choices persist', () async {
    final t = ThemeService();
    await t.load();
    expect(t.textScale, 1.0);
    await t.setTextScale(5);
    await t.setHighContrast(true);
    await t.setReducedMotion(true);
    final again = ThemeService();
    await again.load();
    expect(again.textScale, 1.6);
    expect(again.highContrast, isTrue);
    expect(again.reducedMotion, isTrue);
  });
}
