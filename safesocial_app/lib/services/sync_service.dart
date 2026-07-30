import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crypto/mailbox.dart';
import 'debug_log_service.dart';
import 'identity_service.dart';
import 'relay_service.dart';

/// Manages multi-device synchronization and secure identity cloning.
class SyncService extends ChangeNotifier {
  final RelayService _syncRelay = RelayService();
  
  IdentityService? _identityService;

  bool _isLinking = false;
  bool get isLinking => _isLinking;

  void attachServices(IdentityService iserv) {
    _identityService = iserv;
  }

  /// Start the linking process as the PRIMARY device.
  /// Generates a sync pairing code (ephemeral session secret).
  String startPrimaryLinking() {
    _isLinking = true;
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
  Future<void> startSecondaryLinking(String secretB64) async {
    _isLinking = true;
    notifyListeners();

    _syncRelay.onMessageReceived = (channelKey, data) {
      _handleSecondaryHandshake(data, secretB64);
    };

    await _connectPairing(secretB64);
    
    // Send join request
    final request = jsonEncode({
      'type': 'link_request',
      'device_name': 'New Device',
    });
    
    await _syncRelay.sendViaRelay(_pairingChannel, request);
    DebugLogService().info('Sync', 'Secondary linking started');
  }

  void _handlePrimaryHandshake(String data, String secretB64) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] != 'link_request') return;

      DebugLogService()
          .success('Sync', 'Link request from ${json['device_name']}');

      final identity = _identityService;
      if (identity == null) return;

      // The identity travels as a vault keyed by the pairing secret, which was
      // shown as a QR code and never sent over the relay. The relay therefore
      // carries only ciphertext it has no key for. This previously called a
      // Rust stub that returned null, so nothing was ever transferred.
      final vault = await identity.exportIdentity(secretB64);

      await _syncRelay.sendViaRelay(
        _pairingChannel,
        jsonEncode({'type': 'identity_transfer', 'data': vault}),
      );
      DebugLogService().success('Sync', 'Identity sent to the new device');
    } catch (e) {
      DebugLogService().error('Sync', 'Could not send identity: $e');
    }
  }

  void _handleSecondaryHandshake(String data, String secretB64) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'identity_transfer') {
        final identity = _identityService;
        if (identity == null) return;

        // Actually adopt it. The old path handed the blob to the Rust core and
        // never wrote it back through IdentityService, so even a successful
        // transfer left the device with no identity.
        final ok = await identity.importIdentity(
          json['data'] as String,
          passphrase: secretB64,
        );
        if (!ok) {
          DebugLogService()
              .error('Sync', 'Transferred identity could not be applied');
          return;
        }
        DebugLogService().success('Sync', 'Identity cloned to this device');

        notifyListeners();
      }
    } catch (e) {
      DebugLogService().error('Sync', 'Handshake error: $e');
    }
  }

  void stopLinking() {
    _syncRelay.disconnectAll();
    _isLinking = false;
    notifyListeners();
  }
}
