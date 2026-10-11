import 'dart:convert';
import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/device.dart';
import 'package:spheres_app/services/contact_service.dart';
import 'package:spheres_app/services/outbox_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// What a contact's device list does to their entry, and what the outbox does
/// with a message that went to several devices.
void main() {
  late ed.KeyPair bob;
  late String bobId, bobSecret;

  DeviceList bobList(List<String> keys, {int? version}) => DeviceList.sign(
        identityKey: bobId,
        identitySecret: bobSecret,
        version: version,
        devices: [
          for (var i = 0; i < keys.length; i++)
            DeviceCert.issue(
              identityKey: bobId,
              identitySecret: bobSecret,
              deviceId: '0$i',
              exchangeKey: keys[i],
            ),
        ],
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    bob = ed.generateKey();
    bobId = hex.encode(bob.publicKey.bytes);
    bobSecret = hex.encode(bob.privateKey.bytes);
  });

  Future<ContactService> withBob() async {
    final contacts = ContactService();
    contacts.setMyInfo('me', 'Me');
    await contacts.addContact(bobId, 'Bob',
        keyExchangePublicKey: 'aa' * 32, announce: false);
    return contacts;
  }

  test('a contact with no device list has one device: the key we hold', () async {
    final contacts = await withBob();
    expect(contacts.devicesOf(bobId), ['aa' * 32]);
  });

  test('a verified device list replaces the single key', () async {
    final contacts = await withBob();
    final ready = <String>[];
    contacts.onContactReady = ready.add;

    final ok = await contacts.applyDeviceList(
        bobId, bobList(['aa' * 32, 'bb' * 32], version: 10).toJson());

    expect(ok, isTrue);
    expect(contacts.devicesOf(bobId), ['aa' * 32, 'bb' * 32]);
    expect(contacts.exchangeKeyFor(bobId), 'aa' * 32, reason: 'kept as primary');
    expect(ready, [bobId], reason: 'new devices need channels');
  });

  test('an older list cannot roll a newer one back', () async {
    final contacts = await withBob();
    await contacts.applyDeviceList(bobId, bobList(['aa' * 32, 'bb' * 32], version: 10).toJson());

    final rolled = await contacts.applyDeviceList(bobId, bobList(['aa' * 32], version: 5).toJson());

    expect(rolled, isFalse);
    expect(contacts.devicesOf(bobId), hasLength(2));
  });

  test('a revocation (newer, shorter list) takes effect', () async {
    final contacts = await withBob();
    await contacts.applyDeviceList(bobId, bobList(['aa' * 32, 'bb' * 32], version: 10).toJson());

    await contacts.applyDeviceList(bobId, bobList(['bb' * 32], version: 11).toJson());

    expect(contacts.devicesOf(bobId), ['bb' * 32]);
    expect(contacts.exchangeKeyFor(bobId), 'bb' * 32,
        reason: 'the primary moved to a device that still exists');
  });

  test('a list signed by someone else is ignored', () async {
    final contacts = await withBob();
    final mallory = ed.generateKey();
    final forged = DeviceList.sign(
      identityKey: bobId,
      identitySecret: hex.encode(mallory.privateKey.bytes),
      devices: [
        DeviceCert.issue(
          identityKey: bobId,
          identitySecret: hex.encode(mallory.privateKey.bytes),
          deviceId: '09',
          exchangeKey: 'ee' * 32,
        ),
      ],
    );

    expect(await contacts.applyDeviceList(bobId, forged.toJson()), isFalse);
    expect(contacts.devicesOf(bobId), ['aa' * 32]);
  });

  test('a list for a different identity cannot be applied to this contact', () async {
    final contacts = await withBob();
    final carol = ed.generateKey();
    final carolId = hex.encode(carol.publicKey.bytes);
    final list = DeviceList.sign(
      identityKey: carolId,
      identitySecret: hex.encode(carol.privateKey.bytes),
      devices: [
        DeviceCert.issue(
            identityKey: carolId,
            identitySecret: hex.encode(carol.privateKey.bytes),
            deviceId: '01',
            exchangeKey: 'cc' * 32),
      ],
    );
    expect(await contacts.applyDeviceList(bobId, list.toJson()), isFalse);
  });

  test('device lists survive a reload of the contact list', () async {
    final contacts = await withBob();
    await contacts.applyDeviceList(bobId, bobList(['aa' * 32, 'bb' * 32], version: 10).toJson());

    final again = ContactService();
    await again.loadContacts();
    expect(again.devicesOf(bobId), ['aa' * 32, 'bb' * 32]);
  });

  test('a change here is offered to our other devices, and theirs applies here',
      () async {
    final contacts = await withBob();
    final ops = <Map<String, dynamic>>[];
    contacts.onContactsChanged = (op) async => ops.add(op);

    await contacts.renameContact(bobId, 'Robert');
    expect(ops.single['op'], 'upsert');
    expect(ops.single['contact']['displayName'], 'Robert');

    final other = ContactService();
    other.setMyInfo('me', 'Me');
    await other.applyContactSync(ops.single);
    expect(other.getContact(bobId)?.displayName, 'Robert');

    await other.applyContactSync({'op': 'remove', 'publicKey': bobId});
    expect(other.getContact(bobId), isNull);
  });

  test('a request one device took from the inbox reaches the others, and so does the decision',
      () async {
    // Device A held the request (the inbox hands it to whoever polls first).
    final a = ContactService();
    a.setMyInfo('me', 'Me');
    final opsFromA = <Map<String, dynamic>>[];
    a.onContactsChanged = (op) async => opsFromA.add(op);

    final request = {
      'op': 'request',
      'request': {
        'publicKey': bobId,
        'displayName': 'Bob',
        'keyExchangePublicKey': 'ab' * 32,
        'receivedAt': DateTime(2026, 10, 11).toIso8601String(),
      },
    };

    // Device B learns of it from A's sync and shows it.
    final b = ContactService();
    b.setMyInfo('me', 'Me');
    await b.applyContactSync(request);
    expect(b.requests.single.publicKey, bobId);
    expect(b.requests.single.displayName, 'Bob');

    // A decides; B follows without being asked again.
    await a.applyContactSync(request);
    expect(a.requests, hasLength(1));
    await a.declineRequest(bobId);
    expect(opsFromA.last['op'], 'request_resolved');
    expect(opsFromA.last['declined'], isTrue);
    await b.applyContactSync(opsFromA.last);
    expect(b.requests, isEmpty);

    // Once declined there, a repeat does not come back here either.
    await b.applyContactSync(request);
    expect(b.requests, isEmpty, reason: 'the decline is remembered');
  });

  test('an acceptance that lands on the device that did not ask still creates the contact',
      () async {
    // Device A asked; the shared inbox handed the answer to device B.
    final b = ContactService();
    b.setMyInfo('me', 'Me');
    final synced = <Map<String, dynamic>>[];
    b.onContactsChanged = (op) async => synced.add(op);

    await b.handleIncomingHandshake(bobId, jsonEncode({
      'type': 'contact_accept',
      'name': 'Bob',
      'publicKey': bobId,
      'keyExchangePublicKey': 'ab' * 32,
    }));

    final bob = b.getContact(bobId);
    expect(bob, isNotNull);
    expect(bob!.isPending, isFalse);
    expect(bob.keyExchangePublicKey, 'ab' * 32);
    expect(synced.any((op) => op['op'] == 'upsert' && op['contact']['publicKey'] == bobId),
        isTrue, reason: 'device A learns that its request was accepted');
  });

  group('outbox with several devices', () {
    test('one message to three devices reads as one message', () async {
      final results = {'d1': true, 'd2': false, 'd3': true};
      final outbox = OutboxService()
        ..send = (peer, payload, {deviceKey}) async => results[deviceKey]!;

      await outbox.enqueueAll(
          id: 'm1', peer: 'bob', payloads: {'d1': 'a', 'd2': 'b', 'd3': 'c'});

      expect(outbox.entries, hasLength(3));
      expect(outbox.stateOf('m1'), OutboxState.pending,
          reason: 'one copy has not reached the relay yet');

      results['d2'] = true;
      await outbox.flush();
      expect(outbox.stateOf('m1'), OutboxState.sent);

      await outbox.markDelivered('m1');
      expect(outbox.stateOf('m1'), OutboxState.delivered);
      expect(outbox.entries.every((e) => e.state == OutboxState.delivered), isTrue);
    });

    test('each copy goes to its own device', () async {
      final seen = <String?>[];
      final outbox = OutboxService()
        ..send = (peer, payload, {deviceKey}) async {
          seen.add(deviceKey);
          return true;
        };
      await outbox.enqueueAll(id: 'm1', peer: 'bob', payloads: {'d1': 'a', 'd2': 'b'});
      expect(seen.toSet(), {'d1', 'd2'});
    });

    test('a single-device message still works as before', () async {
      final seen = <String?>[];
      final outbox = OutboxService()
        ..send = (peer, payload, {deviceKey}) async {
          seen.add(deviceKey);
          return true;
        };
      await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'a');
      expect(seen, [null]);
      expect(outbox.stateOf('m1'), OutboxState.sent);
    });
  });
}
