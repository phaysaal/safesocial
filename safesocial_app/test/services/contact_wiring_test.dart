import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Reported from a real two-device test: A scanned B's QR and got B as a
/// contact, but B never got A — and neither could see the other's sphere posts.
///
/// The cause was that nothing announced when a contact became *usable*. A
/// contact is only usable once their X25519 key is known, and until then every
/// send throws NoSessionException, which callers only log. Channels were opened
/// at exactly one call site, which the inbound-handshake path never reached.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  final alice = 'a' * 64;
  final aliceExchange = 'e' * 64;

  test('a contact added with an exchange key is announced ready', () async {
    final service = ContactService();
    final ready = <String>[];
    service.onContactReady = ready.add;

    await service.addContact(alice, 'Alice',
        keyExchangePublicKey: aliceExchange);

    // This is what opens the chat, call and feed channels.
    expect(ready, [alice]);
  });

  test('a contact added without one is NOT announced yet', () async {
    final service = ContactService();
    final ready = <String>[];
    service.onContactReady = ready.add;

    await service.addContact(alice, 'Alice');

    // Correct: nothing can be encrypted to them, so opening channels would
    // only produce sends that fail.
    expect(ready, isEmpty);
    expect(service.exchangeKeyFor(alice), isNull);
  });

  test('learning the key later announces readiness', () async {
    final service = ContactService();
    await service.addContact(alice, 'Alice');

    final ready = <String>[];
    service.onContactReady = ready.add;

    // As happens when the prekey backfill or a handshake supplies it.
    await service.setExchangeKey(alice, aliceExchange);

    expect(ready, [alice]);
    expect(service.exchangeKeyFor(alice), aliceExchange);
  });

  test('re-setting the same key does not re-announce', () async {
    final service = ContactService();
    await service.addContact(alice, 'Alice',
        keyExchangePublicKey: aliceExchange);

    final ready = <String>[];
    service.onContactReady = ready.add;
    await service.setExchangeKey(alice, aliceExchange);

    // Otherwise every poll tick would reopen every channel.
    expect(ready, isEmpty);
  });

  test('an inbound handshake reaches the scanned party as a request', () async {
    final service = ContactService();
    service.setMyInfo('me', 'Me', exchangeKey: 'x' * 64, secretKey: 'y' * 128);

    final ready = <String>[];
    service.onContactReady = ready.add;

    // What arrives in the handshake inbox when someone scans your code.
    await service.handleIncomingHandshake(
      'me',
      '{"type":"contact_request","name":"Alice","publicKey":"$alice",'
      '"keyExchangePublicKey":"$aliceExchange"}',
    );

    // This direction once produced nothing at all, which is the bug this file
    // exists for. It now produces a decision rather than a fait accompli:
    // the key is kept so approving is instant, but nothing is wired until it.
    expect(service.requests.single.publicKey, alice);
    expect(service.requests.single.keyExchangePublicKey, aliceExchange);
    expect(ready, isEmpty);

    await service.approveRequest(alice);

    expect(service.exchangeKeyFor(alice), aliceExchange);
    expect(ready, [alice]);
  });

  test('a handshake without a public key is ignored', () async {
    final service = ContactService();
    service.setMyInfo('me', 'Me', exchangeKey: 'x' * 64, secretKey: 'y' * 128);

    await service.handleIncomingHandshake('me', '{"type":"contact_request"}');

    expect(service.contacts, isEmpty);
  });
}
