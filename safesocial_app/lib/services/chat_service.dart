import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../models/message.dart';
import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'veilid_service.dart';
import 'rust_core_service.dart';

/// Manages chat conversations via Veilid DHT.
///
/// Each conversation is a DHT record. Subkey 0 holds metadata (message counter),
/// subsequent subkeys hold individual messages. Both parties write to the same
/// record. DHT watches trigger real-time incoming message delivery.
class ChatService extends ChangeNotifier {
  static const _prefsConversationsKey = 'spheres_conversations';
  static const _prefsMsgPrefix = 'spheres_msgs_';

  VeilidService? _veilidService;
  final RelayService _relayService = RelayService();
  final RustCoreService _rustCore = RustCoreService();
  String? _myPublicKey;

  final Map<String, List<Message>> _conversations = {};
  final Map<String, RecordKey> _conversationDhtKeys = {};
  final Map<String, String> _conversationRoles = {}; // 'owner' or 'member'
  String? _activeConversation;

  Map<String, List<Message>> get conversations => Map.unmodifiable(_conversations);
  String? get activeConversation => _activeConversation;

  void attachVeilidService(VeilidService vs) {
    _veilidService = vs;
  }

  /// Set the user's public key and configure relay for incoming messages.
  void setMyPublicKey(String publicKey) {
    _myPublicKey = publicKey;
    _relayService.onMessageReceived = (contactKey, encryptedMsg) {
      _handleRelayMessage(contactKey, encryptedMsg);
    };
  }

  /// Connect relay for a specific contact (called after adding contact).
  void connectRelay(String contactPublicKey) {
    if (_myPublicKey != null) {
      _relayService.connect(_myPublicKey!, contactPublicKey);

      // Initialize secure session in Rust Core (Double Ratchet)
      final sharedSecret = CryptoService.deriveSharedKey(_myPublicKey!, contactPublicKey);
      _rustCore.initiateSession(contactPublicKey, base64Encode(utf8.encode(sharedSecret)));
    }
  }

  /// Create a new conversation DHT record for a contact.
...
