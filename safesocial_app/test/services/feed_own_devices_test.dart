import 'dart:async';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/services/debug_log_service.dart';
import 'package:spheres_app/services/feed_service.dart';
import 'package:spheres_app/services/relay_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Found on hardware: after any restart, a post made on one of Fai's phones
/// never reached the other. The feed opened its channel to our own devices
/// before it had been given our key, returned without a word, and nothing
/// opened it again until the device list changed. A quiet return in that
/// spot is exactly what the house rule forbids.
class _DeadSocket implements RelaySocket {
  @override
  Future<void> get ready => Future.error(Exception('no network in a test'));
  @override
  Stream<dynamic> get stream => const Stream.empty();
  @override
  void send(String frame) {}
  @override
  Future<void> close() async {}
}

void main() {
  late SessionManager sessions;
  late String me;
  late String secret;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    RelayHub.instance.debugReset();
    RelayHub.instance.connector = (_) => _DeadSocket();

    final id = ed.generateKey();
    me = hex.encode(id.publicKey.bytes);
    secret = hex.encode(id.privateKey.bytes);
    sessions = SessionManager();
    await sessions.configure(
      keyExchangeKeyPair: await SpheresCrypto.newKeyExchangeKeyPair(),
      identityKey: me,
      identitySecret: secret,
    );
    // Our identity has one more device besides this one.
    final other = await SpheresCrypto.newKeyExchangeKeyPair();
    final otherKey = hex.encode((await other.extractPublicKey()).bytes);
    sessions.deviceResolver = (k) => k == me ? [otherKey] : const [];
  });

  tearDown(() => RelayHub.instance.debugReset());

  test('opening own-device channels before initSync does nothing, and says so',
      () async {
    final feed = FeedService();
    feed.attachCrypto(sessions, (_) => null);
    final before = DebugLogService().logs.length;

    await feed.connectOwnDevices();

    expect(RelayHub.instance.subscriptionCount, 0);
    final said = DebugLogService().logs.skip(before).map((e) => e.message);
    expect(said, contains(contains('before initSync')));
  });

  test('after initSync the channel to our other device is opened', () async {
    final feed = FeedService();
    feed.attachCrypto(sessions, (_) => null);
    feed.initSync(me, secret, const []);

    await feed.connectOwnDevices();

    expect(RelayHub.instance.subscriptionCount, 1,
        reason: 'one mailbox for our one other device');
  });
}
