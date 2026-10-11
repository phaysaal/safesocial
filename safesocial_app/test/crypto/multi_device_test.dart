import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/device.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/services/secure_store.dart';

/// One person, several phones. Each phone has its own X25519 key; the identity
/// key certifies them. A session exists per pair of devices, so two phones
/// never advance the same chain — which is what used to corrupt a
/// conversation the moment two devices ran at once.
class _Device {
  final String identity;
  final String identitySecret;
  final SimpleKeyPair exchange;
  late final String exchangeKey;
  final SessionManager sessions = SessionManager();

  _Device._(this.identity, this.identitySecret, this.exchange);

  static Future<_Device> create(ed.KeyPair identity) async {
    final d = _Device._(
      hex.encode(identity.publicKey.bytes),
      hex.encode(identity.privateKey.bytes),
      await SpheresCrypto.newKeyExchangeKeyPair(),
    );
    d.exchangeKey = hex.encode((await d.exchange.extractPublicKey()).bytes);
    await d.sessions.configure(
      keyExchangeKeyPair: d.exchange,
      identityKey: d.identity,
      identitySecret: d.identitySecret,
    );
    return d;
  }
}

/// Every device knows every other device's keys, as the device lists would
/// tell them.
void connectAll(List<_Device> devices) {
  for (final d in devices) {
    d.sessions.deviceResolver = (identity) =>
        devices.where((o) => o.identity == identity).map((o) => o.exchangeKey).toList();
  }
}

String? Function(String) resolverFor(List<_Device> devices) =>
    (identity) => devices.firstWhere((d) => d.identity == identity).exchangeKey;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  group('device certificates', () {
    test('a certificate verifies only for the identity that signed it', () {
      final alice = ed.generateKey();
      final mallory = ed.generateKey();
      final cert = DeviceCert.issue(
        identityKey: hex.encode(alice.publicKey.bytes),
        identitySecret: hex.encode(alice.privateKey.bytes),
        deviceId: 'aabbccdd',
        exchangeKey: 'ab' * 32,
      );
      expect(cert.verify(), isTrue);

      final forged = DeviceCert(
        identityKey: hex.encode(mallory.publicKey.bytes),
        deviceId: cert.deviceId,
        exchangeKey: cert.exchangeKey,
        createdAtMs: cert.createdAtMs,
        signature: cert.signature,
      );
      expect(forged.verify(), isFalse);

      final swappedKey = DeviceCert(
        identityKey: cert.identityKey,
        deviceId: cert.deviceId,
        exchangeKey: 'cd' * 32,
        createdAtMs: cert.createdAtMs,
        signature: cert.signature,
      );
      expect(swappedKey.verify(), isFalse, reason: 'the key is what is certified');
    });

    test('a device list verifies as a whole and survives the wire', () {
      final alice = ed.generateKey();
      final id = hex.encode(alice.publicKey.bytes);
      final secret = hex.encode(alice.privateKey.bytes);
      final list = DeviceList.sign(
        identityKey: id,
        identitySecret: secret,
        devices: [
          DeviceCert.issue(identityKey: id, identitySecret: secret, deviceId: '01', exchangeKey: 'aa' * 32, name: 'Phone'),
          DeviceCert.issue(identityKey: id, identitySecret: secret, deviceId: '02', exchangeKey: 'bb' * 32, name: 'Tablet'),
        ],
      );
      expect(list.verify(), isTrue);

      final wire = DeviceList.fromJson(list.toJson())!;
      expect(wire.verify(), isTrue);
      expect(wire.devices.map((d) => d.name), [null, null],
          reason: 'names are the owner\'s business and never leave the device');
      expect(wire.exchangeKeys, ['aa' * 32, 'bb' * 32]);

      // Dropping a device from a signed list breaks the signature.
      final trimmed = DeviceList(
        identityKey: id,
        devices: [list.devices.first],
        version: list.version,
        signature: list.signature,
      );
      expect(trimmed.verify(), isFalse);

      // A certificate from someone else cannot ride in Alice's list.
      final bob = ed.generateKey();
      final bobId = hex.encode(bob.publicKey.bytes);
      final smuggled = DeviceList.sign(
        identityKey: id,
        identitySecret: secret,
        devices: [
          DeviceCert.issue(
              identityKey: bobId,
              identitySecret: hex.encode(bob.privateKey.bytes),
              deviceId: '09',
              exchangeKey: 'cc' * 32),
        ],
      );
      expect(smuggled.verify(), isFalse);
    });
  });

  group('sessions per device pair', () {
    late _Device alice1, alice2, bob1, bob2;

    setUp(() async {
      final alice = ed.generateKey();
      final bob = ed.generateKey();
      alice1 = await _Device.create(alice);
      alice2 = await _Device.create(alice);
      bob1 = await _Device.create(bob);
      bob2 = await _Device.create(bob);
      connectAll([alice1, alice2, bob1, bob2]);
    });

    test('a message to a person is sealed once per device, and each opens its own',
        () async {
      final sealed = await alice1.sessions.sealForDevices(
        peerIdentityKey: bob1.identity,
        fallbackExchangeKey: null,
        type: 'chat',
        plaintext: 'hello both',
      );
      expect(sealed, hasLength(2));
      expect(sealed.map((s) => s.deviceKey).toSet(), {bob1.exchangeKey, bob2.exchangeKey});

      final resolver = resolverFor([alice1, alice2, bob1, bob2]);
      for (final item in sealed) {
        final device = item.deviceKey == bob1.exchangeKey ? bob1 : bob2;
        final opened = await device.sessions.open(raw: item.sealed, resolveExchangeKey: resolver);
        expect(opened.plaintext, 'hello both');
        expect(opened.from, alice1.identity);
        expect(opened.fromDevice, alice1.exchangeKey);
      }

      // The copy for one device is not readable by the other. (Each copy
      // travels in its own mailbox, so this never happens on the wire.)
      for (final item in sealed) {
        final other = item.deviceKey == bob1.exchangeKey ? bob2 : bob1;
        await expectLater(
          other.sessions.open(raw: item.sealed, resolveExchangeKey: resolver),
          throwsA(anything),
        );
      }
    });

    test('our own other devices get a copy, in both directions', () async {
      final toAlice2 = await alice1.sessions.sealForOwnDevices(type: 'chat', plaintext: 'from phone');
      expect(toAlice2.single.deviceKey, alice2.exchangeKey);
      final opened = await alice2.sessions.open(
        raw: toAlice2.single.sealed,
        resolveExchangeKey: resolverFor([alice1, alice2]),
      );
      expect(opened.plaintext, 'from phone');
      expect(opened.from, alice1.identity, reason: 'same identity');
      expect(opened.fromDevice, alice1.exchangeKey);

      final back = await alice2.sessions.sealForOwnDevices(type: 'chat', plaintext: 'from tablet');
      final openedBack = await alice1.sessions.open(
        raw: back.single.sealed,
        resolveExchangeKey: resolverFor([alice1, alice2]),
      );
      expect(openedBack.plaintext, 'from tablet');
    });

    test('a single device has no own copies to make', () async {
      final solo = await _Device.create(ed.generateKey());
      connectAll([solo]);
      expect(await solo.sessions.sealForOwnDevices(type: 'chat', plaintext: 'x'), isEmpty);
    });

    test('devices of one person share no chain: both can send at once', () async {
      // Both of Alice's devices message Bob's one device, interleaved. With a
      // shared chain the second sender would reuse a message key and Bob would
      // reject it as a replay; with per-device chains everything opens.
      final resolver = resolverFor([alice1, alice2, bob1, bob2]);
      final a1 = await alice1.sessions.sealForDevices(
          peerIdentityKey: bob1.identity, fallbackExchangeKey: null, type: 'chat', plaintext: 'a1-1', onlyDevice: bob1.exchangeKey);
      final a2 = await alice2.sessions.sealForDevices(
          peerIdentityKey: bob1.identity, fallbackExchangeKey: null, type: 'chat', plaintext: 'a2-1', onlyDevice: bob1.exchangeKey);
      final a1b = await alice1.sessions.sealForDevices(
          peerIdentityKey: bob1.identity, fallbackExchangeKey: null, type: 'chat', plaintext: 'a1-2', onlyDevice: bob1.exchangeKey);

      final got = <String>[];
      for (final item in [a2.single, a1.single, a1b.single]) {
        got.add((await bob1.sessions.open(raw: item.sealed, resolveExchangeKey: resolver)).plaintext);
      }
      expect(got, ['a2-1', 'a1-1', 'a1-2']);
    });

    test('a message from a device we were never told about is flagged, then opens once we are',
        () async {
      // Bob only knows Alice's first device.
      bob1.sessions.deviceResolver = (identity) =>
          identity == alice1.identity ? [alice1.exchangeKey] : [bob1.exchangeKey, bob2.exchangeKey];

      final fromNewPhone = await alice2.sessions.sealForDevices(
          peerIdentityKey: bob1.identity, fallbackExchangeKey: null, type: 'chat', plaintext: 'new phone', onlyDevice: bob1.exchangeKey);

      await expectLater(
        bob1.sessions.open(raw: fromNewPhone.single.sealed, resolveExchangeKey: (_) => alice1.exchangeKey),
        throwsA(isA<UnknownDeviceException>()
            .having((e) => e.peerKey, 'peer', alice1.identity)
            .having((e) => e.deviceKey, 'device', alice2.exchangeKey)),
      );

      // Device list refreshed.
      connectAll([alice1, alice2, bob1, bob2]);
      final opened = await bob1.sessions.open(
          raw: fromNewPhone.single.sealed, resolveExchangeKey: (_) => alice1.exchangeKey);
      expect(opened.plaintext, 'new phone');
    });

    test('each device pair has its own mailbox', () async {
      final toBob1 = await alice1.sessions.mailboxFor(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey, purpose: 'chat');
      final toBob2 = await alice1.sessions.mailboxFor(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob2.exchangeKey, purpose: 'chat');
      final fromAlice2ToBob1 = await alice2.sessions.mailboxFor(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey, purpose: 'chat');
      expect(toBob1.id, isNot(toBob2.id));
      expect(toBob1.id, isNot(fromAlice2ToBob1.id));

      // And both ends of a pair agree on it.
      final bobSide = await bob1.sessions.mailboxFor(
          peerIdentityKey: alice1.identity, peerKeyExchangePublicKey: alice1.exchangeKey, purpose: 'chat');
      expect(bobSide.id, toBob1.id);
    });

    test('the envelope names the sending device and is rejected if that is tampered',
        () async {
      final sealed = await alice1.sessions.seal(
        peerIdentityKey: bob1.identity,
        peerKeyExchangePublicKey: bob1.exchangeKey,
        type: 'chat',
        plaintext: 'x',
      );
      final envelope = Envelope.decode(sealed);
      expect(envelope.fromDevice, alice1.exchangeKey);
      expect(envelope.version, 3);

      final json = envelope.toJson()..['fd'] = alice2.exchangeKey;
      final tampered = Envelope.fromJson(json);
      expect(() => tampered.verifySignature(), throwsA(isA<EnvelopeException>()));
    });

    test('a session reset is scoped to one device pair', () async {
      final resolver = resolverFor([alice1, alice2, bob1, bob2]);
      final epoch = await alice1.sessions.beginReset(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey);
      expect(epoch, 1);
      expect(alice1.sessions.resetEpochFor(bob1.identity, deviceKey: bob1.exchangeKey), 1);
      expect(alice1.sessions.resetEpochFor(bob1.identity, deviceKey: bob2.exchangeKey), 0);

      await bob1.sessions.adoptReset(
          peerIdentityKey: alice1.identity, peerKeyExchangePublicKey: alice1.exchangeKey, epoch: 1);
      final sealed = await alice1.sessions.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey, type: 'chat', plaintext: 'after');
      expect((await bob1.sessions.open(raw: sealed, resolveExchangeKey: resolver)).plaintext, 'after');

      // Bob's other device, never reset, still works with Alice as before.
      final toBob2 = await alice1.sessions.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob2.exchangeKey, type: 'chat', plaintext: 'untouched');
      expect((await bob2.sessions.open(raw: toBob2, resolveExchangeKey: resolver)).plaintext, 'untouched');
    });

    test('sessions persist keyed by device and reload', () async {
      await alice1.sessions.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey, type: 'chat', plaintext: '1');
      await alice1.sessions.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob2.exchangeKey, type: 'chat', plaintext: '2');

      final reloaded = SessionManager();
      await reloaded.configure(
          keyExchangeKeyPair: alice1.exchange, identityKey: alice1.identity, identitySecret: alice1.identitySecret);
      await reloaded.load();
      // The next message continues each chain where it left off.
      final sealed = await reloaded.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob1.exchangeKey, type: 'chat', plaintext: '3');
      expect(Envelope.decode(sealed).sequence, 1);
      final sealed2 = await reloaded.seal(
          peerIdentityKey: bob1.identity, peerKeyExchangePublicKey: bob2.exchangeKey, type: 'chat', plaintext: '4');
      expect(Envelope.decode(sealed2).sequence, 1);
    });
  });
}
