import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/appreciation_service.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Appreciation that completes: reactions held for the day and delivered
/// together at the person's hour, one line per post with every name, once;
/// or as they happen, if that is the choice. The plan's §12.6.
void main() {
  late List<InboundEvent> events;
  late StreamSubscription<InboundEvent> sub;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    events = [];
    sub = InboundEvents.stream.listen(events.add);
  });
  tearDown(() => sub.cancel());

  AppreciationService build(DateTime Function() clock) {
    final a = AppreciationService();
    a.clock = clock;
    a.resolveName = (k) => {'al': 'Al', 'bo': 'Bo', 'cy': 'Cy'}[k] ?? 'Someone';
    a.describePost = (id) => id == 'p1' ? "your post 'Hello'" : 'your flash';
    return a;
  }

  test('held by default, and nothing is said before the hour', () async {
    var now = DateTime(2026, 10, 25, 9);
    final a = build(() => now);
    await a.load();
    expect(a.daily, isTrue);
    expect(a.record(postId: 'p1', reactor: 'al', emoji: '🙌', onComment: false), isTrue);
    await a.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    expect(a.pendingCount, 1);
  });

  test('at the hour, one line per post with every name, then the day is done', () async {
    var now = DateTime(2026, 10, 25, 9);
    final a = build(() => now);
    await a.load();
    a.record(postId: 'p1', reactor: 'al', emoji: '🙌', onComment: false);
    a.record(postId: 'p1', reactor: 'bo', emoji: '😎', onComment: false);
    a.record(postId: 'p1', reactor: 'cy', emoji: '🙌', onComment: false);
    a.record(postId: 'p2', reactor: 'al', emoji: '🥰', onComment: false);
    now = DateTime(2026, 10, 25, 19, 0);
    await a.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 2);
    final p1 = events.singleWhere((e) => e.route == '/post/p1');
    expect(p1.title, 'Appreciation today');
    expect(p1.body, "Al, Bo and Cy appreciated your post 'Hello' 🙌 😎");
    expect(events.singleWhere((e) => e.route == '/post/p2').body, 'Al appreciated your flash 🥰');
    expect(a.pendingCount, 0);

    // The hour has passed; nothing more today, even with a new reaction.
    a.record(postId: 'p1', reactor: 'bo', emoji: '🙌', onComment: false);
    now = DateTime(2026, 10, 25, 21);
    await a.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 2);
    // Tomorrow at the hour it comes.
    now = DateTime(2026, 10, 26, 19, 1);
    await a.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 3);
  });

  test('a reaction taken back before the hour is never mentioned; the same person twice counts once', () async {
    var now = DateTime(2026, 10, 25, 9);
    final a = build(() => now);
    await a.load();
    a.record(postId: 'p1', reactor: 'al', emoji: '🙌', onComment: false);
    a.record(postId: 'p1', reactor: 'al', emoji: '😎', onComment: false);
    a.record(postId: 'p1', reactor: 'bo', emoji: '🙌', onComment: false);
    a.forget(postId: 'p1', reactor: 'bo');
    now = DateTime(2026, 10, 25, 19);
    await a.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events.single.body, "Al appreciated your post 'Hello' 😎");
  });

  test('held reactions survive a restart, and the chosen hour holds', () async {
    var now = DateTime(2026, 10, 25, 9);
    final a = build(() => now);
    await a.load();
    await a.setTime(21, 30);
    a.record(postId: 'p1', reactor: 'al', emoji: '🙌', onComment: false);
    await Future<void>.delayed(Duration.zero);

    final b = build(() => now);
    await b.load();
    expect(b.pendingCount, 1);
    expect(b.summary, 'Once a day at 21:30');
    now = DateTime(2026, 10, 25, 21, 29);
    await b.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    now = DateTime(2026, 10, 25, 21, 30);
    await b.tick();
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 1);
  });

  test('"as it happens" hands the reaction back to the caller, and delivers what was held', () async {
    var now = DateTime(2026, 10, 25, 9);
    final a = build(() => now);
    await a.load();
    a.record(postId: 'p1', reactor: 'al', emoji: '🙌', onComment: false);
    await a.setDaily(false);
    await Future<void>.delayed(Duration.zero);
    expect(events.length, 1, reason: 'what was held is not lost');
    expect(a.record(postId: 'p1', reactor: 'bo', emoji: '🙌', onComment: false), isFalse);
    expect(a.summary, 'As it happens');
  });
}
