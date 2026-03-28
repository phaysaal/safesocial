import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:veilid/veilid.dart';

import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'identity_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';
import 'veilid_service.dart';

/// Manages multi-device synchronization and secure identity cloning.
class SyncService extends ChangeNotifier {
  final RustCoreService _rustCore = RustCoreService();
  final RelayService _syncRelay = RelayService();
  
  IdentityService? _identityService;
  VeilidService? _veilidService;

  bool _isLinking = false;
  bool get isLinking => _isLinking;

  void attachServices(IdentityService iserv, VeilidService vs) {
    _identityService = iserv;
    _veilidService = vs;
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

    // Derive a temporary room ID for the handshake
    final roomId = _computeHandshakeRoomId(secretB64);
    
    _syncRelay.onMessageReceived = (contactKey, data) {
      _handlePrimaryHandshake(data, secretB64);
    };

    // Connect to handshake room
    _syncRelay.connect('primary', roomId);
    
    DebugLogService().info('Sync', 'Primary linking started. Room: $roomId');
    return secretB64;
  }

  /// Start the linking process as the SECONDARY device.
  Future<void> startSecondaryLinking(String secretB64) async {
    _isLinking = true;
    notifyListeners();

    final roomId = _computeHandshakeRoomId(secretB64);
    
    _syncRelay.onMessageReceived = (contactKey, data) {
      _handleSecondaryHandshake(data, secretB64);
    };

    await _syncRelay.connect('secondary', roomId);
    
    // Send join request
    final request = jsonEncode({
      'type': 'link_request',
      'device_name': 'New Device',
    });
    
    _syncRelay.sendViaRelay('primary', request);
    DebugLogService().info('Sync', 'Secondary linking started. Joining room: $roomId');
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
          _syncRelay.sendViaRelay('secondary', response);
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

  String _computeHandshakeRoomId(String secret) {
    // Salted hash of the secret to find the meeting room
    final combined = 'spheres-sync-handshake-v1-$secret';
    var hash = 0;
    for (var i = 0; i < combined.length; i++) {
      hash = ((hash << 5) - hash + combined.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hash.toRadixString(36).padLeft(12, '0');
  }

  void stopLinking() {
    _syncRelay.disconnectAll();
    _isLinking = false;
    notifyListeners();
  }
}
