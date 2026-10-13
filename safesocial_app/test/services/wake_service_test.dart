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
  void Function(String instance, String? target, WakeKeys? keys)? onEndpoint;
  void Function()? onWake;
  void Function(String instance, WakeFailure reason)? onFailed;

  /// The VAPID key handed over at each start.
  final vapids = <String?>[];

  @override
  String get name => 'Fake';
  @override
  Future<bool> get isAvailable async => available;
  @override
  Future<String?> get unavailableReason async =>
      available ? null : 'no distributor';

  @override
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  }) async {
    this.onEndpoint = onEndpoint;
    this.onWake = onWake;
    this.onFailed = onFailed;
    vapids.add(vapid);
  }

  @override
  Future<void> register(String instance) async => registered.add(instance);
  @override
  Future<void> unregister(String instance) async => unregistered.add(instance);
}

/// The UnifiedPush provider with its platform calls stubbed, so that what is
/// specific to it (distributor switching, naming) can run in a test.
class _FakeUnifiedPush extends UnifiedPushWakeProvider {
  final registered = <String>[];
  final unregistered = <String>[];
  void Function(String instance, String? target, WakeKeys? keys)? onEndpoint;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<void> start({
    required void Function(String instance, String? target, WakeKeys? keys)
        onEndpoint,
    required void Function() onWake,
    void Function(String instance, WakeFailure reason)? onFailed,
    String? vapid,
  }) async {
    this.onEndpoint = onEndpoint;
    distributor = 'io.heckel.ntfy';
  }

  @override
  Future<void> useDistributor(String id) async => distributor = id;

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
  late List<WakeKeys?> toldKeys;
  late WakeService wake;
  late RelayService chat;

  /// What the relay answers when asked for its VAPID key; a throwing
  /// function stands for a relay that cannot be reached.
  late Future<String?> Function() relayVapid;
  var vapidAsks = 0;

  WakeService build({String? Function(String? target)? refuse}) => WakeService(
        provider: provider,
        registerWithRelay: (mailbox, target, keys) async {
          toldRelay.add((mailbox.id, target));
          toldKeys.add(keys);
          return refuse?.call(target);
        },
        fetchVapid: () {
          vapidAsks++;
          return relayVapid();
        },
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RelayHub.instance.debugReset();
    RelayHub.instance.connector = (_) => _FakeSocket();
    RelayHub.instance.syncOverride = (_, __) async => 0;
    provider = _FakeProvider();
    toldRelay = [];
    toldKeys = [];
    vapidAsks = 0;
    relayVapid = () async => null;
    WakeService.registerTimeout = Duration.zero;
    WakeService.retryDelay = Duration.zero;
    wake = build();
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

    provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
    await settle();

    expect(toldRelay, [(a.id, 'https://ntfy.example/abc')]);
    expect(wake.registeredCount, 1);

    // The same endpoint again is not re-sent.
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
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
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
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
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
    await settle();

    provider.onEndpoint!(a.id, null, null);
    await settle();

    expect(toldRelay.last, (a.id, null));
    expect(wake.registeredCount, 0);
  });

  test('a relay refusal is kept for Settings to show', () async {
    wake = build(refuse: (_) => 'APNs is not configured on this relay');
    await wake.load();
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();

    provider.onEndpoint!(a.id, 'apns:abcd', null);
    await settle();

    expect(wake.lastError, contains('not configured'));
    expect(wake.registeredCount, 0);
  });

  test('switching off clears everything; switching on starts again', () async {
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
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
    await wake.registrationsSettled;
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

  group('Web Push keys and VAPID', () {
    // The Play build's built-in distributor registers with Google Play
    // services and gives the endpoint together with the device's Web Push
    // keys; Google's service only takes a knock signed with the relay's
    // VAPID key and only delivers one that carries bytes. So the keys must
    // reach the relay, and the relay's key must reach the distributor.
    const keys = WakeKeys(p256dh: 'BPub', auth: 'auth');

    test('the keys that come with an endpoint are passed to the relay',
        () async {
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();

      provider.onEndpoint!(a.id, 'https://fcm.googleapis.com/fcm/send/t1', keys);
      await settle();

      expect(toldRelay, [(a.id, 'https://fcm.googleapis.com/fcm/send/t1')]);
      expect(toldKeys, [keys]);
    });

    test('an endpoint without keys (ntfy) is registered as before', () async {
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();

      provider.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
      await settle();

      expect(toldKeys, [null]);
    });

    test("the relay's VAPID key is fetched once and handed to the provider",
        () async {
      relayVapid = () async => 'BRelayKey';
      await wake.start();
      await wake.start();

      expect(provider.vapids, ['BRelayKey']);
      expect(vapidAsks, 1);
      expect(wake.vapid, 'BRelayKey');
    });

    test('a relay without a key, or out of reach, starts the provider with none',
        () async {
      relayVapid = () async => throw Exception('offline');
      await wake.start();

      expect(provider.vapids, [null]);
      expect(wake.vapid, isNull);
      expect(wake.started, isTrue, reason: 'ntfy needs no key; do not stall');
    });

    test('a VAPID refusal is retried once with a fresh key from the relay',
        () async {
      // The first ask found the relay unreachable; the distributor then said
      // it needs the key. One more ask, and the registration goes again.
      var reachable = false;
      relayVapid = () async {
        if (!reachable) throw Exception('offline');
        return 'BRelayKey';
      };
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();
      expect(provider.registered, [a.id]);

      reachable = true;
      provider.onFailed!(a.id, WakeFailure.vapidRequired);
      await settle();
      await settle();

      expect(provider.vapids, [null, 'BRelayKey']);
      expect(provider.registered, [a.id, a.id], reason: 'registered again');
      expect(wake.lastError, isNull);
    });

    test('a VAPID refusal with the relay still keyless is shown, not retried forever',
        () async {
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();

      provider.onFailed!(a.id, WakeFailure.vapidRequired);
      await settle();
      provider.onFailed!(a.id, WakeFailure.vapidRequired);
      await settle();

      expect(vapidAsks, 2, reason: 'the start and one retry');
      expect(wake.lastError, contains('VAPID'));
      expect(provider.registered, [a.id]);
    });

    test('any other refusal from the distributor is kept for Settings', () async {
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();

      provider.onFailed!(a.id, WakeFailure.actionRequired);
      await settle();

      expect(wake.lastError, contains('needs you'));
    });
  });

  test('switching distributor withdraws the old registrations and ignores their late answers',
      () async {
    // Seen as a risk on paper: ntfy answers "unregistered" after Google has
    // already given the new endpoint, and that answer used to clear the
    // relay's target, leaving the phone with no wake at all.
    WakeService.switchSettle = Duration.zero;
    final up = _FakeUnifiedPush();
    wake = WakeService(
      provider: up,
      registerWithRelay: (mailbox, target, keys) async {
        toldRelay.add((mailbox.id, target));
        return null;
      },
      fetchVapid: () async => 'BRelayKey',
    );
    await wake.load();
    await wake.start();
    final a = await mailbox('a');
    await chat.connectMailbox('alice', a);
    await settle();
    up.onEndpoint!(a.id, 'https://ntfy.example/abc', null);
    await settle();
    expect(toldRelay, [(a.id, 'https://ntfy.example/abc')]);

    final switching = wake.switchDistributor(UnifiedPushWakeProvider.embeddedDistributor);
    await settle();
    // The new distributor answers, then ntfy's late "unregistered" lands.
    up.onEndpoint!(a.id, 'https://fcm.googleapis.com/fcm/send/t1',
        const WakeKeys(p256dh: 'BPub', auth: 'auth'));
    await settle();
    up.onEndpoint!(a.id, null, null);
    await settle();
    await switching;

    expect(up.unregistered, [a.id]);
    expect(up.registered, [a.id, a.id]);
    expect(up.distributor, UnifiedPushWakeProvider.embeddedDistributor);
    expect(toldRelay.last, (a.id, 'https://fcm.googleapis.com/fcm/send/t1'),
        reason: 'the late answer did not clear the relay');
    expect(up.name, 'Google Play services');
  });

  group('one registration at a time', () {
    // Seen on the tablet with the built-in Google distributor on 13 October
    // 2026: five registrations fired together and one timed out inside Play
    // services' IPC; later, a wake started the services again in a process
    // the system had frozen, the same burst overflowed its binder buffer,
    // and the process crashed with the knock unhandled.
    test('the next registration waits for the answer to the one before',
        () async {
      WakeService.registerTimeout = const Duration(seconds: 30);
      await wake.start();
      final a = await mailbox('a');
      final b = await mailbox('b');
      await chat.connectMailbox('alice', a);
      await chat.connectMailbox('bob', b);
      await settle();
      expect(provider.registered, [a.id], reason: "b waits for a's answer");

      provider.onEndpoint!(a.id, 'https://fcm.googleapis.com/fcm/send/a', null);
      await settle();
      await settle();
      expect(provider.registered, [a.id, b.id]);

      provider.onEndpoint!(b.id, 'https://fcm.googleapis.com/fcm/send/b', null);
      await settle();
      expect(wake.registeredCount, 2);
    });

    test('a distributor that never answers holds the line only so long',
        () async {
      WakeService.registerTimeout = const Duration(milliseconds: 400);
      await wake.start();
      final a = await mailbox('a');
      final b = await mailbox('b');
      await chat.connectMailbox('alice', a);
      await chat.connectMailbox('bob', b);
      await settle();
      expect(provider.registered, [a.id]);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(provider.registered, [a.id, b.id]);
    });

    test('a mailbox is registered once per process, however often the hub '
        'resubscribes or a wake starts the services again', () async {
      WakeService.registerTimeout = const Duration(seconds: 30);
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();
      // Seen on the tablet: a resubscribe while the first answer was still
      // in flight asked a second time.
      RelayHub.instance.onSubscribed?.call(a);
      await settle();
      expect(provider.registered, [a.id], reason: 'still waiting for the answer');
      provider.onEndpoint!(a.id, 'https://fcm.googleapis.com/fcm/send/a', null);
      await settle();
      expect(provider.registered, [a.id]);

      await wake.start();
      RelayHub.instance.onSubscribed?.call(a);
      await wake.start();
      await settle();

      expect(provider.registered, [a.id], reason: 'nothing new to ask for');
      expect(wake.registeredCount, 1);
    });

    test('an internal error in the distributor is retried once, then shown',
        () async {
      await wake.start();
      final a = await mailbox('a');
      await chat.connectMailbox('alice', a);
      await settle();
      expect(provider.registered, [a.id]);

      provider.onFailed!(a.id, WakeFailure.internalError);
      await settle();
      await settle();
      await settle();
      expect(provider.registered, [a.id, a.id], reason: 'one more go');
      expect(wake.lastError, isNull);

      provider.onFailed!(a.id, WakeFailure.internalError);
      await settle();
      await settle();
      await settle();
      expect(provider.registered, [a.id, a.id], reason: 'not forever');
      expect(wake.lastError, contains('could not register'));

      // An endpoint at last clears the slate for a later failure.
      provider.onEndpoint!(a.id, 'https://fcm.googleapis.com/fcm/send/a', null);
      await settle();
      expect(wake.lastError, isNull);
    });
  });

  test('the built-in Google distributor is named for what it is', () {
    expect(UnifiedPushWakeProvider.describe('com.spheres.spheres_app'),
        'Google Play services (built in)');
    expect(UnifiedPushWakeProvider.describe('io.heckel.ntfy'), 'io.heckel.ntfy');
  });
}
