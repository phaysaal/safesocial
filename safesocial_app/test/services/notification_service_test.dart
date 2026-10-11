import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/inbound_events.dart';
import 'package:spheres_app/services/notification_service.dart';

class _Shown {
  final String title, body, thread, route;
  final bool high;
  _Shown(this.title, this.body, this.thread, this.route, this.high);
}

class _FakeSink implements NotificationSink {
  final shown = <_Shown>[];
  final cancelled = <String>[];
  bool initialized = false;

  @override
  Future<void> initialize({required void Function(String route) onTap}) async {
    initialized = true;
  }

  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String thread,
    required String route,
    required bool highPriority,
  }) async {
    shown.add(_Shown(title, body, thread, route, highPriority));
  }

  @override
  Future<void> cancelThread(String thread) async => cancelled.add(thread);
}

InboundEvent chat({String id = 'm1', String body = 'hello'}) => InboundEvent(
      kind: InboundKind.chat,
      id: 'chat:$id',
      title: 'Alice',
      body: body,
      route: '/chat/alicekey',
      thread: 'chat:alicekey',
    );

const call = InboundEvent(
  kind: InboundKind.call,
  id: 'call:1',
  title: 'Alice',
  body: 'Incoming voice call',
  route: '/call',
  thread: 'call:alicekey',
);

/// Notifications are built on the device from decrypted content, after the
/// user's rules. These pin the rules.
void main() {
  late _FakeSink sink;
  late NotificationService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLifecycle.foreground = false;
    sink = _FakeSink();
    service = NotificationService(sink: sink);
    await service.load();
    await service.start();
  });

  tearDown(() => service.dispose());

  test('a message arriving in the background is shown with its text', () async {
    expect(await service.handle(chat()), isTrue);
    expect(sink.shown.single.title, 'Alice');
    expect(sink.shown.single.body, 'hello');
    expect(sink.shown.single.route, '/chat/alicekey');
    expect(sink.shown.single.high, isFalse);
  });

  test('nothing is shown while the app is on screen, except a call', () async {
    AppLifecycle.foreground = true;
    expect(await service.handle(chat()), isFalse);
    expect(await service.handle(call), isTrue);
    expect(sink.shown.single.high, isTrue);
  });

  test('the same event twice notifies once', () async {
    expect(await service.handle(chat()), isTrue);
    expect(await service.handle(chat()), isFalse);
    expect(sink.shown, hasLength(1));
  });

  test('with previews off, only who it is from is shown', () async {
    await service.setPreview(false);
    await service.handle(chat(body: 'the secret plan'));
    expect(sink.shown.single.body, 'New message');
    expect(sink.shown.single.title, 'Alice');
  });

  test('a kind the user switched off is not shown', () async {
    await service.setAllowed(InboundKind.chat, false);
    expect(await service.handle(chat()), isFalse);
    expect(service.allows(InboundKind.chat), isFalse);
    expect(service.allows(InboundKind.call), isTrue);
  });

  test('switched off entirely, nothing is shown', () async {
    await service.setEnabled(false);
    expect(await service.handle(chat()), isFalse);
    expect(await service.handle(call), isFalse);
  });

  test('preferences survive a reload', () async {
    await service.setPreview(false);
    await service.setAllowed(InboundKind.post, false);

    final again = NotificationService(sink: _FakeSink());
    await again.load();
    expect(again.preview, isFalse);
    expect(again.allows(InboundKind.post), isFalse);
    expect(again.allows(InboundKind.chat), isTrue);
  });

  test('events on the bus reach the sink', () async {
    InboundEvents.emit(chat(id: 'bus'));
    await Future<void>.delayed(Duration.zero);
    expect(sink.shown.single.title, 'Alice');
  });

  test('opening a thread clears its notifications', () async {
    await service.clearThread('chat:alicekey');
    expect(sink.cancelled, ['chat:alicekey']);
  });

  group('permission is asked once per install', () {
    test('the first call asks, later calls and later launches do not', () async {
      SharedPreferences.setMockInitialValues({});
      final sink = _FakeSink();
      final service = NotificationService(sink: sink);
      await service.load();
      expect(service.permissionAsked, isFalse);

      expect(await service.ensurePermissionAsked(), isTrue);
      expect(await service.ensurePermissionAsked(), isNull);
      expect(sink.permissionRequests, 1);

      // A fresh service on the same install remembers the question was put.
      final again = NotificationService(sink: _FakeSink());
      await again.load();
      expect(again.permissionAsked, isTrue);
      expect(await again.ensurePermissionAsked(), isNull);
    });
  });
}
