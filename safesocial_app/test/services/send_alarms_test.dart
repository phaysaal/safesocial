import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/services/chat_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/send_alarms.dart';

/// A scheduled message or post used to go only while the app was running:
/// a phone asleep at the minute sent it when the app next opened, and said
/// nothing. Now one platform alarm follows the schedule. What is pinned: the
/// alarm is the earliest pending time across chat and feed, it moves when
/// the schedule changes, it is cleared when nothing waits, and where there
/// is no platform at all nothing claims a wake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  late ChatService chat;
  late FeedService feed;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SendAlarms.channel, (call) async {
      calls.add(call);
      return call.method == 'set' || call.method == 'exact' ? true : null;
    });
    final k = ed.generateKey();
    final me = hex.encode(k.publicKey.bytes);
    final secret = hex.encode(k.privateKey.bytes);
    chat = ChatService();
    chat.setMyInfo(me, secret, sessions: SessionManager(), resolveExchangeKey: (_) => null);
    feed = FeedService();
    feed.initSync(me, secret, const []);
    chat.onScheduleChanged = () => SendAlarms.resync(chat, feed);
    feed.onScheduleChanged = () => SendAlarms.resync(chat, feed);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SendAlarms.channel, null);
  });

  test('earliest of nothing is nothing, otherwise the soonest', () {
    expect(SendAlarms.earliest(const []), isNull);
    expect(SendAlarms.earliest([DateTime(2026, 10, 13, 9), DateTime(2026, 10, 13, 8)]),
        DateTime(2026, 10, 13, 8));
  });

  test('the alarm follows the schedule across chat and feed', () async {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final tonight = DateTime.now().add(const Duration(hours: 2));

    final m = await chat.scheduleMessage('bob', 'later', tomorrow);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'set');
    expect(calls.last.arguments['at'], tomorrow.millisecondsSinceEpoch);

    final draft = await feed.saveDraft(
        content: 'post', mediaRefs: const [], sphereIds: {'s'}, scheduledFor: tonight);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.arguments['at'], tonight.millisecondsSinceEpoch,
        reason: 'the sooner one wins, whichever service it is in');

    await feed.deleteDraft(draft);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.arguments['at'], tomorrow.millisecondsSinceEpoch);

    await chat.cancelScheduled(m.id);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'cancel', reason: 'nothing waits, no wake');
  });

  test('without platform code nothing is set and nothing is promised', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SendAlarms.channel, null);
    expect(await SendAlarms.exactAllowed(), isFalse);
    await chat.scheduleMessage('bob', 'later', DateTime.now().add(const Duration(hours: 1)));
    expect(await SendAlarms.resync(chat, feed), isFalse);
  });
}
