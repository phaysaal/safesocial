import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// Adding a contact used to be unilateral: anyone holding your public key put
/// themselves in your address book, and the "Pending approval" label they were
/// given never cleared because nothing was ever waiting on an approval. That
/// sat oddly beside spheres, where joining has always required an explicit yes.
///
/// A request is now held until the person decides, and until then nothing is
/// wired for the sender and nothing is sent back to them.
void main() {
  final alice = 'a' * 64;
  final aliceExchange = 'e' * 64;
  final bob = 'b' * 64;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  ContactService serviceForMe() {
    final service = ContactService();
    service.setMyInfo('me', 'Me', exchangeKey: 'x' * 64, secretKey: 'y' * 128);
    return service;
  }

  String requestFrom(String key, String name, {String? exchange}) =>
      jsonEncode({
        'type': 'contact_request',
        'name': name,
        'publicKey': key,
        if (exchange != null) 'keyExchangePublicKey': exchange,
      });

  group('an incoming request', () {
    test('is held, not accepted', () async {
      final service = serviceForMe();

      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      expect(service.requests.single.publicKey, alice);
      // The important half: they are not in the address book yet.
      expect(service.contacts, isEmpty);
    });

    test('wires nothing until it is approved', () async {
      // Opening channels for someone unapproved would let them reach the
      // screen before the decision was made.
      final service = serviceForMe();
      final ready = <String>[];
      service.onContactReady = ready.add;

      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice', exchange: aliceExchange));

      expect(ready, isEmpty);
    });

    test('keeps the key it arrived with, so approving needs no round trip',
        () async {
      final service = serviceForMe();

      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice', exchange: aliceExchange));

      expect(service.requests.single.keyExchangePublicKey, aliceExchange);
    });

    test('a repeat replaces rather than stacks up', () async {
      final service = serviceForMe();

      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));
      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice B.', exchange: aliceExchange));

      expect(service.requests, hasLength(1));
      expect(service.requests.single.displayName, 'Alice B.');
      expect(service.requests.single.keyExchangePublicKey, aliceExchange);
    });

    test('one without a public key is ignored', () async {
      final service = serviceForMe();

      await service.handleIncomingHandshake(
          'me', jsonEncode({'type': 'contact_request', 'name': 'Nobody'}));

      expect(service.requests, isEmpty);
    });

    test('survives a restart', () async {
      final service = serviceForMe();
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      final restarted = ContactService();
      await restarted.loadContacts();

      expect(restarted.requests.single.publicKey, alice);
    });
  });

  group('approving', () {
    test('makes them a contact, with no waiting label', () async {
      final service = serviceForMe();
      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice', exchange: aliceExchange));

      await service.approveRequest(alice);

      expect(service.requests, isEmpty);
      final contact = service.contacts.single;
      expect(contact.publicKey, alice);
      // They asked us, so nothing is pending on their side either.
      expect(contact.isPending, isFalse);
    });

    test('opens their channels', () async {
      final service = serviceForMe();
      final ready = <String>[];
      service.onContactReady = ready.add;
      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice', exchange: aliceExchange));

      await service.approveRequest(alice);

      expect(ready, [alice]);
    });

    test('approving something that is not there does nothing', () async {
      final service = serviceForMe();

      await service.approveRequest(bob);

      expect(service.contacts, isEmpty);
    });
  });

  group('declining', () {
    test('removes the request without adding a contact', () async {
      final service = serviceForMe();
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      await service.declineRequest(alice);

      expect(service.requests, isEmpty);
      expect(service.contacts, isEmpty);
    });

    test('a declined person cannot simply ask again', () async {
      // Otherwise "no" lasts only until they tap the button a second time.
      final service = serviceForMe();
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));
      await service.declineRequest(alice);

      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      expect(service.requests, isEmpty);
    });

    test('a refusal survives a restart', () async {
      final service = serviceForMe();
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));
      await service.declineRequest(alice);

      final restarted = serviceForMe();
      await restarted.loadContacts();
      await restarted.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      expect(restarted.requests, isEmpty);
    });

    test('it can be undone if they change their mind about someone', () async {
      final service = serviceForMe();
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));
      await service.declineRequest(alice);

      await service.undoDecline(alice);
      await service.handleIncomingHandshake('me', requestFrom(alice, 'Alice'));

      expect(service.requests, hasLength(1));
    });
  });

  group('the side that asked', () {
    test('is marked as waiting until the other approves', () async {
      final service = serviceForMe();

      await service.addContact(alice, 'Alice',
          keyExchangePublicKey: aliceExchange);

      expect(service.contacts.single.isPending, isTrue);
    });

    test('stops waiting when the acceptance arrives', () async {
      // The old label never cleared, because nothing ever cleared it.
      final service = serviceForMe();
      await service.addContact(alice, 'Alice',
          keyExchangePublicKey: aliceExchange);

      await service.handleIncomingHandshake(
        'me',
        jsonEncode({
          'type': 'contact_accept',
          'name': 'Alice',
          'publicKey': alice,
          'keyExchangePublicKey': aliceExchange,
        }),
      );

      expect(service.contacts.single.isPending, isFalse);
    });

    test('a request from someone we already added needs no decision', () async {
      // Both sides adding each other at once should just connect, not ask.
      final service = serviceForMe();
      await service.addContact(alice, 'Alice');

      await service.handleIncomingHandshake(
          'me', requestFrom(alice, 'Alice', exchange: aliceExchange));

      expect(service.requests, isEmpty);
      expect(service.exchangeKeyFor(alice), aliceExchange);
    });
  });
}
