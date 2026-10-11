import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/mailbox.dart';
import '../crypto/spheres_crypto.dart';
import 'backup_service.dart';
import 'debug_log_service.dart';
import 'identity_service.dart';
import 'relay_service.dart';

/// Adding a device to an identity.
///
/// The new device generates its own X25519 key and device id and announces
/// them over a pairing mailbox derived from a code shown on the first device.
/// The first device certifies the new device with the identity key, adds it
/// to the signed device list, and sends everything the new device needs — the
/// identity, contacts, spheres and their keys, history — as a backup sealed
/// under the pairing code. The relay carries only ciphertext it has no key
/// for.
///
/// The new device restores that backup *as a new device*: it keeps the X25519
/// key it generated rather than the first device's, so the two never share a
/// session. Contacts learn about it from the device list, which the first
/// device publishes and announces. From then on both devices work at once.
class SyncService extends ChangeNotifier {
  final RelayService _syncRelay = RelayService();
  final _secureStorage = const FlutterSecureStorage();

  IdentityService? _identityService;

  /// Called after a received identity has been written, so the app can reload
  /// every service. Set by the app.
  Future<void> Function()? onIdentityReceived;

  bool _isLinking = false;
  bool get isLinking => _isLinking;

  /// What the primary knows about the device it is linking, for the UI.
  String? pendingDeviceName;

  /// Set when linking finished on either side, for the UI.
  String? lastResult;

  void attachServices(IdentityService iserv) {
    _identityService = iserv;
  }

  /// Start the linking process as the PRIMARY device.
  /// Generates a sync pairing code (ephemeral session secret).
  String startPrimaryLinking() {
    _isLinking = true;
    pendingDeviceName = null;
    lastResult = null;
    notifyListeners();

    // Generate random 32-byte session secret
    final random = Random.secure();
    final secretBytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      secretBytes[i] = random.nextInt(256);
    }
    final secretB64 = base64Encode(secretBytes);

    _syncRelay.onMessageReceived = (channelKey, data) {
      _handlePrimaryHandshake(data, secretB64);
    };

    // Both devices derive the same address from the pairing secret. Previously
    // one joined deriveRelayRoomId('primary', roomId) and the other
    // deriveRelayRoomId('secondary', roomId) — two different rooms — and then
    // sent to channel keys that were never registered, so linking could never
    // complete.
    _connectPairing(secretB64);

    DebugLogService().info('Sync', 'Primary linking started');
    return secretB64;
  }

  /// Channel key for the pairing session. Local handle only.
  static const _pairingChannel = 'device-pairing';

  Future<void> _connectPairing(String secretB64) async {
    final mailbox = await Mailbox.fromLocalSecret(
      secret: secretB64,
      purpose: 'device-pairing',
    );
    await _syncRelay.connectMailbox(_pairingChannel, mailbox);
  }

  /// Start the linking process as the SECONDARY device.
  ///
  /// Generates this device's own key pair and id first, so the request can
  /// carry them and the primary can certify them.
  Future<void> startSecondaryLinking(String secretB64,
      {String deviceName = 'New device'}) async {
    _isLinking = true;
    lastResult = null;
    notifyListeners();

    // Our own X25519 key, written where IdentityService will find it after the
    // backup is restored. The primary's key is deliberately not taken.
    final pair = await SpheresCrypto.newKeyExchangeKeyPair();
    await _secureStorage.write(
      key: 'spheres_identity_x25519_secret',
      value: hex.encode(await pair.extractPrivateKeyBytes()),
    );
    final exchangeKey = hex.encode((await pair.extractPublicKey()).bytes);

    var deviceId = await _secureStorage.read(key: 'spheres_device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = hex.encode(SpheresCrypto.randomBytes(8));
      await _secureStorage.write(key: 'spheres_device_id', value: deviceId);
    }

    _syncRelay.onMessageReceived = (channelKey, data) {
      _handleSecondaryHandshake(data, secretB64);
    };

    await _connectPairing(secretB64);

    // Send join request
    final request = jsonEncode({
      'type': 'link_request',
      'device_name': deviceName,
      'device_id': deviceId,
      'exchange_key': exchangeKey,
    });

    await _syncRelay.sendViaRelay(_pairingChannel, request);
    DebugLogService().info('Sync', 'Secondary linking started');
  }

  void _handlePrimaryHandshake(String data, String secretB64) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] != 'link_request') return;

      final name = json['device_name'];
      final deviceId = json['device_id'];
      final exchangeKey = json['exchange_key'];
      pendingDeviceName = name is String ? name : 'New device';
      notifyListeners();
      DebugLogService().success('Sync', 'Link request from $pendingDeviceName');

      final identity = _identityService;
      if (identity == null) return;

      if (deviceId is! String ||
          exchangeKey is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(exchangeKey)) {
        DebugLogService().error('Sync', 'Link request without a usable device key');
        lastResult = 'The other device sent no usable key. Update it and try again.';
        notifyListeners();
        return;
      }

      // Certify the new device and add it to the list before the backup is
      // built, so the list the new device receives already includes itself.
      await identity.addLinkedDevice(
        deviceId: deviceId,
        exchangeKey: exchangeKey,
        name: pendingDeviceName,
      );

      // Everything the new device needs, sealed under the pairing code, which
      // was shown on this screen and never sent over the relay.
      final vault = await BackupService().buildBackupData(passphrase: secretB64);

      await _syncRelay.sendViaRelay(
        _pairingChannel,
        jsonEncode({'type': 'identity_transfer', 'data': vault}),
      );
      lastResult = 'Sent to $pendingDeviceName. It is now one of your devices.';
      notifyListeners();
      DebugLogService().success('Sync', 'Identity sent to the new device');
    } catch (e) {
      lastResult = 'Could not send the identity: $e';
      notifyListeners();
      DebugLogService().error('Sync', 'Could not send identity: $e');
    }
  }

  void _handleSecondaryHandshake(String data, String secretB64) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'identity_transfer') {
        // Restore as a new device: keep the key we generated, take everything
        // else. Then let the app reload every service around the new identity.
        await BackupService().restoreBackupData(
          json['data'] as String,
          passphrase: secretB64,
          asNewDevice: true,
        );
        DebugLogService().success('Sync', 'Identity received on this device');
        await onIdentityReceived?.call();
        lastResult = 'This device is now linked.';
        _isLinking = false;
        notifyListeners();
        _syncRelay.disconnectAll();
      }
    } catch (e) {
      lastResult = 'Could not apply the identity: $e';
      notifyListeners();
      DebugLogService().error('Sync', 'Handshake error: $e');
    }
  }

  void stopLinking() {
    _syncRelay.disconnectAll();
    _isLinking = false;
    notifyListeners();
  }
}
