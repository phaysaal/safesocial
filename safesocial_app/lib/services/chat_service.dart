// Real implementation uses package:veilid/veilid.dart for:
// - DHT-backed conversation records (subkey 0 = metadata, 1+ = messages)
// - RecordKey for conversation addressing
// - VeilidRoutingContext for DHT read/write with privacy
// - watchDHTValues for incoming message notifications
// Stubbed out until Android NDK + Rust toolchain issues are resolved.
// See pubspec.yaml for the veilid dependency (currently commented out).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';

/// Manages chat conversations and message exchange.
///
/// Stub implementation that keeps messages in-memory and persists
/// conversation metadata to SharedPreferences. When Veilid is available,
/// messages will be exchanged via DHT records.
class ChatService extends ChangeNotifier {
  static const _conversationsPrefsKey = 'spheres_conversations';
  static const _msgsCachePrefix = 'spheres_msgs_';

  final Map<String, List<Message>> _conversations = {};
  final Map<String, String> _conversationKeys = {}; // contactId -> mock DHT key
  String? _activeConversation;

  Map<String, List<Message>> get conversations =>
      Map.unmodifiable(_conversations);
  String? get activeConversation => _activeConversation;

  /// Create a new conversation for chatting with a contact.
  /// Returns a mock conversation key string.
  ///
  /// Real implementation:
  /// Future<RecordKey?> createConversation(String contactPublicKey, KeyPair writerKeypair) async {
  ///   final schema = DHTSchema.dflt(oCnt: 512);
  ///   final record = await rc.createDHTRecord(bestCryptoKind, schema);
  ///   await rc.watchDHTValues(record.key);
  ///   ...
  /// }
  Future<String?> createConversation(String contactPublicKey) async {
    final mockKey = const Uuid().v4();
    _conversationKeys[contactPublicKey] = mockKey;
    _conversations.putIfAbsent(contactPublicKey, () => []);
    await _persistConversationKeys();
    notifyListeners();

    debugPrint('[ChatService] Created local conversation for $contactPublicKey');
    return mockKey;
  }

  /// Send a message to a recipient.
  Future<void> sendMessage(String recipientId, String content,
      {List<String>? mediaRefs}) async {
    final message = Message(
      id: const Uuid().v4(),
      senderId: 'self',
      recipientId: recipientId,
      content: content,
      timestamp: DateTime.now(),
      delivered: true, // Stub: always "delivered" locally
      mediaRefs: mediaRefs ?? [],
    );

    _conversations.putIfAbsent(recipientId, () => []);
    _conversations[recipientId]!.add(message);
    notifyListeners();

    // Real implementation writes to DHT:
    // await rc.openDHTRecord(dhtKey);
    // await rc.setDHTValue(dhtKey, nextSubkey, encodedMessage);
    // await rc.closeDHTRecord(dhtKey);

    await _cacheMessages(recipientId);
  }

  /// Handle a DHT value change event (incoming message from a contact).
  ///
  /// Stub: no-op. Real implementation reads changed subkeys from the
  /// conversation DHT record and adds new messages to the local list.
  /// Future<void> handleValueChange(RecordKey key, List<ValueSubkeyRange> subkeys) async { ... }
  Future<void> handleValueChange(String key, List<dynamic> subkeys) async {
    // No-op in stub — Veilid is not connected.
    debugPrint('[ChatService] handleValueChange stub called');
  }

  /// Join an existing conversation by its key (received from contact exchange).
  ///
  /// Real implementation:
  /// Future<void> joinConversation(String contactPublicKey, RecordKey dhtKey) async {
  ///   await rc.openDHTRecord(dhtKey);
  ///   await rc.watchDHTValues(dhtKey);
  ///   ...
  /// }
  Future<void> joinConversation(String contactPublicKey, String key) async {
    _conversationKeys[contactPublicKey] = key;
    _conversations.putIfAbsent(contactPublicKey, () => []);
    await _persistConversationKeys();
    notifyListeners();
  }

  Future<List<Message>> getMessages(String conversationId) async {
    return _conversations[conversationId] ?? [];
  }

  void setActiveConversation(String? id) {
    _activeConversation = id;
    notifyListeners();
  }

  List<String> getConversationIds() {
    return _conversations.keys.toList();
  }

  void receiveMessage(Message message) {
    final conversationId = message.senderId;
    _conversations.putIfAbsent(conversationId, () => []);
    _conversations[conversationId]!.add(message);
    notifyListeners();
  }

  /// Load conversation keys and cached messages from SharedPreferences.
  ///
  /// Real implementation uses Veilid's TableStore:
  /// final db = await Veilid.instance.openTableDB(_tableDbName, 1);
  /// final keysJson = await db.loadStringJson(0, 'conversation_keys');
  /// ...
  Future<void> loadConversations() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final keysJson = prefs.getString(_conversationsPrefsKey);
      if (keysJson != null) {
        final keysMap = jsonDecode(keysJson) as Map<String, dynamic>;
        for (final entry in keysMap.entries) {
          _conversationKeys[entry.key] = entry.value as String;
          _conversations.putIfAbsent(entry.key, () => []);
        }
      }

      // Load cached messages for each conversation
      for (final contactId in _conversationKeys.keys) {
        final msgsJson = prefs.getString('$_msgsCachePrefix$contactId');
        if (msgsJson != null) {
          final msgsList = jsonDecode(msgsJson) as List<dynamic>;
          _conversations[contactId] = msgsList
              .map((m) => Message.fromJson(m as Map<String, dynamic>))
              .toList();
        }
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[ChatService] Failed to load conversations: $e');
    }
  }

  Future<void> _cacheMessages(String contactId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final msgs = _conversations[contactId] ?? [];
      await prefs.setString(
        '$_msgsCachePrefix$contactId',
        jsonEncode(msgs.map((m) => m.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ChatService] Failed to cache messages: $e');
    }
  }

  Future<void> _persistConversationKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _conversationsPrefsKey,
        jsonEncode(_conversationKeys),
      );
    } catch (e) {
      debugPrint('[ChatService] Failed to persist conversation keys: $e');
    }
  }
}
