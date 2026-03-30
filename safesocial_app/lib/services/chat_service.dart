import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

/// Manages chat conversations via Veilid DHT.
class ChatService extends ChangeNotifier {
  static const _prefsConversationsKey = 'spheres_conversations';
  static const _prefsMsgPrefix = 'spheres_msgs_';

  final RelayService _relayService = RelayService();
  final RustCoreService _rustCore = RustCoreService();
  String? _myPublicKey;

  final Map<String, List<Message>> _conversations = {};
  final Map<String, String> _conversationRoles = {}; 
  String? _activeConversation;

  Map<String, List<Message>> get conversations => Map.unmodifiable(_conversations);
  String? get activeConversation => _activeConversation;


  void setActiveConversation(String? conversationId) {
    _activeConversation = conversationId;
    notifyListeners();
  }

  void setMyPublicKey(String publicKey) {
    _myPublicKey = publicKey;
    _relayService.onMessageReceived = (contactKey, encryptedMsg) {
      _handleRelayMessage(contactKey, encryptedMsg);
    };
  }

  void connectRelay(String contactPublicKey) {
    if (_myPublicKey != null) {
      _relayService.connect(_myPublicKey!, contactPublicKey);
      final sharedSecret = CryptoService.deriveSharedKey(_myPublicKey!, contactPublicKey);
      _rustCore.initiateSession(contactPublicKey, base64Encode(utf8.encode(sharedSecret)));
    }
  }

  bool isRelayConnected(String contactPublicKey) => _relayService.isConnected(contactPublicKey);

  List<String> getConversationIds() => _conversations.keys.toList();

  Future<void> sendMessage(String contactPublicKey, String content, {List<String>? mediaRefs, String? audioRef}) async {
    final message = Message(
      id: const Uuid().v4(),
      senderId: _myPublicKey ?? 'self',
      recipientId: contactPublicKey,
      content: content,
      timestamp: DateTime.now(),
      mediaRefs: mediaRefs ?? [],
      audioRef: audioRef,
    );

    _addMessageLocally(contactPublicKey, message);

    // 1. Send via Relay
    final sharedKey = CryptoService.deriveSharedKey(_myPublicKey ?? '', contactPublicKey);
    final encrypted = CryptoService.encrypt(jsonEncode(message.toJson()), sharedKey);
    _relayService.sendViaRelay(contactPublicKey, encrypted);


  }



  void _handleRelayMessage(String contactKey, String encryptedMsg) {
    try {
      final sharedKey = CryptoService.deriveSharedKey(_myPublicKey ?? '', contactKey);
      final decrypted = CryptoService.decrypt(encryptedMsg, sharedKey);
      final msg = Message.fromJson(jsonDecode(decrypted));
      _addMessageLocally(contactKey, msg);
    } catch (e) {
      DebugLogService().error('Chat', 'Failed to handle relay message: $e');
    }
  }

  void _addMessageLocally(String contactKey, Message msg) {
    _conversations.putIfAbsent(contactKey, () => []);
    if (!_conversations[contactKey]!.any((m) => m.id == msg.id)) {
      _conversations[contactKey]!.add(msg);
      _conversations[contactKey]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _persistMessages(contactKey);
      notifyListeners();
    }
  }

  Future<void> loadConversations() async {
    final prefs = await SharedPreferences.getInstance();
    final keysJson = prefs.getString(_prefsConversationsKey);
    if (keysJson != null) {
      final Map<String, dynamic> keys = jsonDecode(keysJson);
      for (var entry in keys.entries) {
        _conversations[entry.key] = [];
        await _loadMessages(entry.key);
      }
    }
    notifyListeners();
  }

  Future<void> _loadMessages(String contactKey) async {
    final prefs = await SharedPreferences.getInstance();
    final msgsJson = prefs.getString('$_prefsMsgPrefix$contactKey');
    if (msgsJson != null) {
      final List<dynamic> msgs = jsonDecode(msgsJson);
      _conversations[contactKey] = msgs.map((m) => Message.fromJson(m)).toList();
    }
  }

  Future<void> _persistMessages(String contactKey) async {
    final prefs = await SharedPreferences.getInstance();
    final msgs = _conversations[contactKey] ?? [];
    await prefs.setString('$_prefsMsgPrefix$contactKey', jsonEncode(msgs.map((m) => m.toJson()).toList()));
    
    final keys = _conversations.keys.toList();
    await prefs.setString(_prefsConversationsKey, jsonEncode(Map.fromIterable(keys)));
  }

  void removeConversation(String contactKey) {
    _conversations.remove(contactKey);
    
    _persistConversationKeys();
    notifyListeners();
  }

  void deleteMessage(String contactKey, String messageId) {
    _conversations[contactKey]?.removeWhere((m) => m.id == messageId);
    _persistMessages(contactKey);
    notifyListeners();
  }

  Future<void> _persistConversationKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = _conversations.keys.toList();
    await prefs.setString(_prefsConversationsKey, jsonEncode(Map.fromIterable(keys)));
  }

  Future<void> createConversation(String contactPublicKey) async {
    _conversations.putIfAbsent(contactPublicKey, () => []);
    notifyListeners();
  }
}
