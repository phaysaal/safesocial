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
