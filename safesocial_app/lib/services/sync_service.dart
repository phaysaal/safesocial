import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../crypto/mailbox.dart';
import 'debug_log_service.dart';
import 'identity_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

/// Manages multi-device synchronization and secure identity cloning.
class SyncService extends ChangeNotifier {
  final RustCoreService _rustCore = RustCoreService();
  final RelayService _syncRelay = RelayService();
  
  // Held but never read: a received identity is passed to the (non-functional)
  // Rust core and never written back through IdentityService, so linking could
  // not have persisted anything even if the relay handshake had worked. The UI
  // entry points are disabled; rebuilding this is Phase 5 of docs/rebuild_plan.md.
  // ignore: unused_field
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
      if (json['type'] == 'link_request') {
        DebugLogService().success('Sync', 'Link request received from ${json['device_name']}');
        
        // Export identity wrapped with the session secret
        final wrappedIdentity = _rustCore.exportIdentity(secretB64);
        if (wrappedIdentity != null) {
          final response = jsonEncode({
            'type': 'identity_transfer',
            'data': wrappedIdentity,
          });
          await _syncRelay.sendViaRelay(_pairingChannel, response);
          DebugLogService().success('Sync', 'Encrypted identity transferred to new device');
        }
      }
    } catch (e) {
      DebugLogService().error('Sync', 'Handshake error: $e');
    }
  }

  void _handleSecondaryHandshake(String data, String secretB64) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'identity_transfer') {
        DebugLogService().success('Sync', 'Encrypted identity received');
        
        // Import identity into Rust core and local storage
        _rustCore.importIdentity(json['data'], secretB64);
        
        // Finalize
        _isLinking = false;
        notifyListeners();
        DebugLogService().success('Sync', 'Identity successfully cloned!');
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
