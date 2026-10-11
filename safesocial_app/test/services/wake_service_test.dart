import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/mailbox.dart';
import 'package:spheres_app/services/relay_service.dart';
import 'package:spheres_app/services/wake_service.dart';

/// A provider the test drives by hand.
class _FakeProvider implements WakeProvider {
  bool available = true;
  final registered = <String>[];
  final unregistered = <String>[];
  void Function(String instance, String? target)? onEndpoint;
  void Function()? onWake;

  @override
  String get name => 'Fake';
  @override
  Future<bool> get isAvailable async => available;
  @override
  Future<String?> get unavailableReason async =>
      available ? null : 'no distributor';

  @override
  Future<void> start({
    required void Function(String instance, String? target) onEndpoint,
    required void Function() onWake,
  }) async {
    this.onEndpoint = onEndpoint;
    this.onWake = onWake;
  }

  @override
  Future<void> register(String instance) async => registered.add(instance);
  @override
  Future<void> unregister(String instance) async => unregistered.add(instance);
}

class _FakeSocket implements RelaySocket {
  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => const Stream.empty();
  @override
  void send(String frame) {}
  @override
  Future<void> close() async {}
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

/// The relay knocks on a wake endpoint per mailbox when nobody is listening.
/// These pin how the client keeps the relay's idea of "where to knock" in
/// step with the mailboxes it actually holds.
void main() {
  late _FakeProvider provider;
  late List<(String, String?)> toldRelay;
  late WakeService wake;
  late RelayService chat;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RelayHub.instance.debugReset();
    RelayHub.instance.connector = (_) => _FakeSocket();
    RelayHub.instance.syncOverride = (_, __) async => 0;
    provider = _FakeProvider();
    toldRelay = [];
    wake = WakeService(
      provider: provider,
      registerWithRelay: (mailbox, target) async {
        toldRelay.add((mailbox.id, target));
        return null;
      },
    );
    await wake.load();
    chat = RelayService();
  });

  tearDown(() => RelayHub.instance.debugReset());

  Future<Mailbox> mailbox(String secret) =>
      Mailbox.fromLocalSecret(secret: secret, purpose: 'test');

  test('each subscribed mailbox gets its own provider registration', () async {
    await wake.start();
    final a = await mailbox('a');
    final b = await mailbox('b');
    await chat.connectMailbox('alice', a);
    await chat.connectMailbox('bob', b);
    await settle();

    expect(provider.registered, containsAll([a.id, b.id]));
    expect(toldRelay, isEmpty, reason: 'no endpoint yet, nothing to tell');
  });

  test('an endpoint from the provider is registered with the relay', () async {
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    provider.onEndpoint!(a.id, 'https://ntfy.example/abc');
    await settle();

    expect(toldRelay, [(a.id, 'https://ntfy.example/abc')]);
    expect(wake.registeredCount, 1);

    // The same endpoint again is not re-sent.
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc');
    await settle();
    expect(toldRelay, hasLength(1));
  });

  test('mailboxes already held when the service starts are registered too',
      () async {
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    await wake.start();
    expect(provider.registered, [a.id]);
  });

  test('dropping a mailbox clears its wake target and provider registration',
      () async {
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc');
    await settle();

    chat.disconnect('alice');
    await settle();

    expect(toldRelay.last, (a.id, null));
    expect(provider.unregistered, [a.id]);
    expect(wake.registeredCount, 0);
  });

  test('a lost endpoint is cleared at the relay', () async {
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc');
    await settle();

    provider.onEndpoint!(a.id, null);
    await settle();

    expect(toldRelay.last, (a.id, null));
    expect(wake.registeredCount, 0);
  });

  test('a relay refusal is kept for Settings to show', () async {
    wake = WakeService(
      provider: provider,
      registerWithRelay: (_, __) async => 'APNs is not configured on this relay',
    );
    await wake.load();
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    provider.onEndpoint!(a.id, 'apns:abcd');
    await settle();

    expect(wake.lastError, contains('not configured'));
    expect(wake.registeredCount, 0);
  });

  test('switching off clears everything; switching on starts again', () async {
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc');
    await settle();

    await wake.setEnabled(false);
    expect(toldRelay.last, (a.id, null));
    expect(provider.unregistered, [a.id]);
    expect(wake.registeredCount, 0);

    final b = await mailbox('b');
    await chat.connectMailbox('bob', b);
    await settle();
    expect(provider.registered, [a.id], reason: 'off: nothing new registered');

    await wake.setEnabled(true);
    expect(provider.registered, containsAll([a.id, b.id]));
  });

  test('an unavailable provider is reported, not pretended', () async {
    provider.available = false;
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    expect(wake.started, isFalse);
    expect(provider.registered, isEmpty);
  });

  test('a wake from the provider reaches the app', () async {
    var woken = 0;
    wake.onWake = () => woken++;
    await wake.start();
    provider.onWake!();
    expect(woken, 1);
  });
}
