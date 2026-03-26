import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../models/message.dart';
import 'veilid_service.dart';

/// Manages chat conversations via Veilid DHT.
///
/// Each conversation is a DHT record. Subkey 0 holds metadata (message counter),
/// subsequent subkeys hold individual messages. Both parties write to the same
/// record. DHT watches trigger real-time incoming message delivery.
class ChatService extends ChangeNotifier {
  static const _prefsConversationsKey = 'spheres_conversations';
  static const _prefsMsgPrefix = 'spheres_msgs_';

  VeilidService? _veilidService;

  final Map<String, List<Message>> _conversations = {};
  final Map<String, RecordKey> _conversationDhtKeys = {};
  String? _activeConversation;

  Map<String, List<Message>> get conversations => Map.unmodifiable(_conversations);
  String? get activeConversation => _activeConversation;

  void attachVeilidService(VeilidService vs) {
    _veilidService = vs;
  }

  /// Create a new conversation DHT record for a contact.
  /// If writerKeypair is null, creates a local-only conversation.
  Future<RecordKey?> createConversation(String contactPublicKey, [KeyPair? writerKeypair]) async {
    final rc = _veilidService?.routingContext;
    if (rc == null) {
      debugPrint('[ChatService] No routing context — creating local conversation');
      _conversations.putIfAbsent(contactPublicKey, () => []);
      await _persistConversationKeys();
      notifyListeners();
      return null;
    }

    try {
      final schema = DHTSchema.dflt(oCnt: 512);
      final record = await rc.createDHTRecord(bestCryptoKind, schema);

      // Initialize counter at subkey 0
      final meta = {'next_subkey': 1};
      await rc.setDHTValue(
        record.key, 0,
        Uint8List.fromList(utf8.encode(jsonEncode(meta))),
      );

      // Watch for incoming messages
      await rc.watchDHTValues(record.key);
      await rc.closeDHTRecord(record.key);

      _conversationDhtKeys[contactPublicKey] = record.key;
      _conversations.putIfAbsent(contactPublicKey, () => []);
      await _persistConversationKeys();
      notifyListeners();

      debugPrint('[ChatService] Created DHT conversation: ${record.key}');
      return record.key;
    } catch (e) {
      debugPrint('[ChatService] Failed to create DHT conversation: $e');
      _conversations.putIfAbsent(contactPublicKey, () => []);
      notifyListeners();
      return null;
    }
  }

  /// Send a message — writes to DHT if connected, stores locally always.
  Future<void> sendMessage(String recipientId, String content,
      {List<String>? mediaRefs}) async {
    final message = Message(
      id: const Uuid().v4(),
      senderId: 'self',
      recipientId: recipientId,
      content: content,
      timestamp: DateTime.now(),
      delivered: false,
      mediaRefs: mediaRefs ?? [],
    );

    _conversations.putIfAbsent(recipientId, () => []);
    _conversations[recipientId]!.add(message);
    notifyListeners();

    // Write to DHT if connected
    final rc = _veilidService?.routingContext;
    final dhtKey = _conversationDhtKeys[recipientId];
    if (rc != null && dhtKey != null) {
      try {
        await rc.openDHTRecord(dhtKey);

        // Read current counter
        final metaData = await rc.getDHTValue(dhtKey, 0);
        int nextSubkey = 1;
        if (metaData != null) {
          final meta = jsonDecode(utf8.decode(metaData.data)) as Map<String, dynamic>;
          nextSubkey = meta['next_subkey'] as int? ?? 1;
        }

        // Write message
        final msgJson = {
          'id': message.id,
          'sender': message.senderId,
          'recipient': message.recipientId,
          'content': message.content,
          'timestamp': message.timestamp.millisecondsSinceEpoch,
          'media_refs': message.mediaRefs,
        };
        await rc.setDHTValue(
          dhtKey, nextSubkey,
          Uint8List.fromList(utf8.encode(jsonEncode(msgJson))),
        );

        // Increment counter
        await rc.setDHTValue(
          dhtKey, 0,
          Uint8List.fromList(utf8.encode(jsonEncode({'next_subkey': nextSubkey + 1}))),
        );

        await rc.closeDHTRecord(dhtKey);

        // Mark delivered
        final idx = _conversations[recipientId]!.indexWhere((m) => m.id == message.id);
        if (idx != -1) {
          _conversations[recipientId]![idx] = message.copyWith(delivered: true);
          notifyListeners();
        }

        debugPrint('[ChatService] Message sent to DHT subkey $nextSubkey');
      } catch (e) {
        debugPrint('[ChatService] DHT write failed: $e');
      }
    }

    await _cacheMessages(recipientId);
  }

  /// Handle DHT value change — incoming message from contact.
  Future<void> handleValueChange(RecordKey key, List<ValueSubkeyRange> subkeys) async {
    final rc = _veilidService?.routingContext;
    if (rc == null) return;

    // Find which conversation
    String? contactId;
    for (final entry in _conversationDhtKeys.entries) {
      if (entry.value == key) {
        contactId = entry.key;
        break;
      }
    }
    if (contactId == null) return;

    try {
      await rc.openDHTRecord(key);

      for (final range in subkeys) {
        for (int sk = range.low; sk <= range.high; sk++) {
          if (sk == 0) continue;

          final data = await rc.getDHTValue(key, sk, forceRefresh: true);
          if (data == null) continue;

          try {
            final msgJson = jsonDecode(utf8.decode(data.data)) as Map<String, dynamic>;
            final senderId = msgJson['sender'] as String? ?? '';
            if (senderId == 'self') continue;

            final msgId = msgJson['id'] as String;
            if (_conversations[contactId]?.any((m) => m.id == msgId) ?? false) continue;

            final message = Message(
              id: msgId,
              senderId: senderId,
              recipientId: msgJson['recipient'] as String? ?? '',
              content: msgJson['content'] as String? ?? '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(msgJson['timestamp'] as int? ?? 0),
              delivered: true,
              mediaRefs: (msgJson['media_refs'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
            );

            _conversations.putIfAbsent(contactId, () => []);
            _conversations[contactId]!.add(message);
            debugPrint('[ChatService] Received message from $senderId');
          } catch (e) {
            debugPrint('[ChatService] Parse error at subkey $sk: $e');
          }
        }
      }

      await rc.closeDHTRecord(key);
      notifyListeners();
      await _cacheMessages(contactId);
    } catch (e) {
      debugPrint('[ChatService] Value change handling failed: $e');
    }
  }

  /// Join an existing conversation using a string key (from QR payload).
  Future<void> joinConversationByString(String contactPublicKey, String dhtKeyStr) async {
    _conversations.putIfAbsent(contactPublicKey, () => []);

    final rc = _veilidService?.routingContext;
    if (rc != null) {
      try {
        final dhtKey = RecordKey.fromString(dhtKeyStr);
        _conversationDhtKeys[contactPublicKey] = dhtKey;
        await rc.openDHTRecord(dhtKey);
        await rc.watchDHTValues(dhtKey);
        await rc.closeDHTRecord(dhtKey);
        debugPrint('[ChatService] Joined conversation: $dhtKeyStr');
      } catch (e) {
        debugPrint('[ChatService] Failed to join by string: $e');
      }
    }

    await _persistConversationKeys();
    notifyListeners();
  }

  /// Join an existing conversation by DHT key (from contact exchange).
  Future<void> joinConversation(String contactPublicKey, RecordKey dhtKey) async {
    _conversationDhtKeys[contactPublicKey] = dhtKey;
    _conversations.putIfAbsent(contactPublicKey, () => []);

    final rc = _veilidService?.routingContext;
    if (rc != null) {
      try {
        await rc.openDHTRecord(dhtKey);
        await rc.watchDHTValues(dhtKey);
        await rc.closeDHTRecord(dhtKey);
      } catch (e) {
        debugPrint('[ChatService] Failed to watch conversation: $e');
      }
    }

    await _persistConversationKeys();
    notifyListeners();
  }

  /// Remove a conversation and all its messages.
  Future<void> removeConversation(String contactPublicKey) async {
    _conversations.remove(contactPublicKey);
    _conversationDhtKeys.remove(contactPublicKey);
    await _persistConversationKeys();

    // Remove cached messages
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefsMsgPrefix$contactPublicKey');
    } catch (_) {}

    notifyListeners();
  }

  Future<List<Message>> getMessages(String conversationId) async {
    return _conversations[conversationId] ?? [];
  }

  void setActiveConversation(String? id) {
    _activeConversation = id;
    notifyListeners();
  }

  List<String> getConversationIds() => _conversations.keys.toList();

  void receiveMessage(Message message) {
    final conversationId = message.senderId;
    _conversations.putIfAbsent(conversationId, () => []);
    _conversations[conversationId]!.add(message);
    notifyListeners();
  }

  /// Load conversations from TableStore or SharedPreferences.
  Future<void> loadConversations() async {
    try {
      if (_veilidService?.isInitialized == true) {
        try {
          final db = await Veilid.instance.openTableDB('spheres_conversations', 1);
          try {
            final keysJson = await db.loadStringJson(0, 'conversation_keys');
            if (keysJson != null) {
              final keysMap = keysJson as Map<String, dynamic>;
              for (final entry in keysMap.entries) {
                _conversationDhtKeys[entry.key] = RecordKey.fromJson(entry.value);
                _conversations.putIfAbsent(entry.key, () => []);
              }
            }
          } finally { db.close(); }
        } catch (e) {
          debugPrint('[ChatService] TableStore load failed: $e');
        }
      }

      // Fallback: SharedPreferences for cached messages
      final prefs = await SharedPreferences.getInstance();
      final keysJson = prefs.getString(_prefsConversationsKey);
      if (keysJson != null && _conversationDhtKeys.isEmpty) {
        final keysMap = jsonDecode(keysJson) as Map<String, dynamic>;
        for (final entry in keysMap.entries) {
          _conversations.putIfAbsent(entry.key, () => []);
        }
      }

      // Load cached messages
      for (final contactId in _conversations.keys) {
        final msgsJson = prefs.getString('$_prefsMsgPrefix$contactId');
        if (msgsJson != null) {
          final msgsList = jsonDecode(msgsJson) as List<dynamic>;
          _conversations[contactId] = msgsList
              .map((m) => Message.fromJson(m as Map<String, dynamic>))
              .toList();
        }
      }

      // Re-watch all conversations
      final rc = _veilidService?.routingContext;
      if (rc != null) {
        for (final dhtKey in _conversationDhtKeys.values) {
          try {
            await rc.openDHTRecord(dhtKey);
            await rc.watchDHTValues(dhtKey);
            await rc.closeDHTRecord(dhtKey);
          } catch (_) {}
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
        '$_prefsMsgPrefix$contactId',
        jsonEncode(msgs.map((m) => m.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[ChatService] Cache failed: $e');
    }
  }

  Future<void> _persistConversationKeys() async {
    if (_veilidService?.isInitialized == true) {
      try {
        final db = await Veilid.instance.openTableDB('spheres_conversations', 1);
        try {
          final keysMap = <String, dynamic>{};
          for (final entry in _conversationDhtKeys.entries) {
            keysMap[entry.key] = entry.value.toJson();
          }
          await db.storeStringJson(0, 'conversation_keys', keysMap);
        } finally { db.close(); }
      } catch (e) {
        debugPrint('[ChatService] TableStore persist failed: $e');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final keysMap = <String, String>{};
      for (final entry in _conversationDhtKeys.entries) {
        keysMap[entry.key] = entry.value.toString();
      }
      await prefs.setString(_prefsConversationsKey, jsonEncode(keysMap));
    } catch (e) {
      debugPrint('[ChatService] SharedPreferences persist failed: $e');
    }
  }
}
