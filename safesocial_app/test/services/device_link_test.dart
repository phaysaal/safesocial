import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/device.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/services/backup_service.dart';
import 'package:spheres_app/services/identity_service.dart';
import 'package:spheres_app/services/secure_store.dart';

/// The linking flow, replayed in one process: a primary certifies the new
/// device's key and sends a backup; the new device, which already holds that
/// key, restores the backup as a new device and loads.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
  });

  test('a linked device keeps the key the primary certified and both devices stay listed',
      () async {
    // Primary.
    final primary = IdentityService();
    await primary.createIdentity('Fai');
    final primaryKey = primary.exchangePublicKey!;

    // What the secondary generates before asking to be linked.
    final pair = await SpheresCrypto.newKeyExchangeKeyPair();
    final secondarySecret = hex.encode(await pair.extractPrivateKeyBytes());
    final secondaryKey = hex.encode((await pair.extractPublicKey()).bytes);

    await primary.addLinkedDevice(
        deviceId: 'd2d2d2d2d2d2d2d2', exchangeKey: secondaryKey, name: 'Moto');
    expect(primary.deviceList!.devices, hasLength(2));
    final backup = await BackupService().buildBackupData(passphrase: 'pairing-code');

    // Secondary: a fresh device holding only its own generated key and id.
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'spheres_identity_x25519_secret': secondarySecret,
      'spheres_device_id': 'd2d2d2d2d2d2d2d2',
    });
    await SecureStore.instance.init();
    await BackupService()
        .restoreBackupData(backup, passphrase: 'pairing-code', asNewDevice: true);

    final secondary = IdentityService();
    await secondary.loadIdentity();

    expect(secondary.publicKey, primary.publicKey);
    expect(secondary.exchangePublicKey, secondaryKey,
        reason: 'the certified key must survive the restore');
    final list = secondary.deviceList!;
    expect(list.devices.map((d) => d.exchangeKey), containsAll([primaryKey, secondaryKey]),
        reason: 'the restored list names both devices');
    expect(list.verify(), isTrue);
    expect(secondary.deviceExchangeKeys, containsAll([primaryKey, secondaryKey]));
  });

  test('a newer list from another of our devices that omits us is a revocation',
      () async {
    final me = IdentityService();
    await me.createIdentity('Fai');
    final myKey = me.exchangePublicKey!;
    expect(me.thisDeviceRevoked, isFalse);

    final other = await SpheresCrypto.newKeyExchangeKeyPair();
    final otherKey = hex.encode((await other.extractPublicKey()).bytes);
    final cert = DeviceCert.issue(
      identityKey: me.publicKey!,
      identitySecret: me.secretKey!,
      deviceId: 'eeeeeeeeeeeeeeee',
      exchangeKey: otherKey,
      name: 'Other',
    );
    final withoutMe = DeviceList.sign(
      identityKey: me.publicKey!,
      identitySecret: me.secretKey!,
      devices: [cert],
      version: DateTime.now().millisecondsSinceEpoch + 1000,
    );

    expect(await me.adoptDeviceList(jsonDecode(jsonEncode(withoutMe.toJson()))), isTrue);
    expect(me.deviceList!.hasExchangeKey(myKey), isFalse);
    expect(me.thisDeviceRevoked, isTrue,
        reason: 'the UI says so and contacts stop sending here');
  });
}
