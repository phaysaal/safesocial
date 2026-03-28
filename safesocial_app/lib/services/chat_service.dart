import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../models/message.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
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
  final RelayService _relayService = RelayService();
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
    }
  }

  /// Create a new conversation DHT record for a contact.
  ///
  /// Uses SMPL schema so both the creator AND the contact can write.
  /// Owner gets subkeys 0-255, contact member gets subkeys 256-511.
  Future<RecordKey?> createConversation(String contactPublicKey, [KeyPair? writerKeypair]) async {
    final rc = _veilidService?.routingContext;
    if (rc == null) {
      DebugLogService().info('Chat',' No routing context — creating local conversation');
      _conversations.putIfAbsent(contactPublicKey, () => []);
      await _persistConversationKeys();
      notifyListeners();
      return null;
    }

    try {
      // Parse the contact's public key to create a member ID
      final contactKey = PublicKey.fromString(contactPublicKey);
      final memberId = await Veilid.instance.generateMemberId(contactKey);

      // SMPL schema: owner gets 256 subkeys, contact member gets 256 subkeys
      final schema = DHTSchema.smpl(
        oCnt: 256,
        members: [
          DHTSchemaMember(mKey: memberId.value, mCnt: 256),
        ],
      );

      final record = await rc.createDHTRecord(bestCryptoKind, schema);

      // Initialize metadata at subkey 0 (owner subkey range)
      final meta = {
        'owner_next': 1,      // next subkey for owner to write (1-255)
        'member_next': 256,   // next subkey for member to write (256-511)
      };
      await rc.setDHTValue(
        record.key, 0,
        Uint8List.fromList(utf8.encode(jsonEncode(meta))),
      );

      // Watch for incoming messages
      await rc.watchDHTValues(record.key);
      await rc.closeDHTRecord(record.key);

      _conversationDhtKeys[contactPublicKey] = record.key;
      _conversations.putIfAbsent(contactPublicKey, () => []);
      // Track if we're the owner of this conversation
      _conversationRoles[contactPublicKey] = 'owner';
      await _persistConversationKeys();
      notifyListeners();

      DebugLogService().info('Chat',' Created SMPL conversation: ${record.key}');
      return record.key;
    } catch (e) {
      DebugLogService().info('Chat',' Failed to create conversation: $e');
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
      senderId: _myPublicKey ?? 'self',
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

        // Determine which subkey range to use based on our role
        final role = _conversationRoles[recipientId] ?? 'member';

        // Track write position locally (members can't write to metadata subkey 0)
        final localCounterKey = '${_prefsMsgPrefix}counter_${recipientId}';
        final prefs = await SharedPreferences.getInstance();
        int nextSubkey;

        if (role == 'owner') {
          // Owner reads from DHT metadata
          final metaData = await rc.getDHTValue(dhtKey, 0);
          if (metaData != null) {
            final meta = jsonDecode(utf8.decode(metaData.data)) as Map<String, dynamic>;
            nextSubkey = meta['owner_next'] as int? ?? 1;
          } else {
            nextSubkey = 1;
          }
        } else {
          // Member tracks position locally
          nextSubkey = prefs.getInt(localCounterKey) ?? 256;
        }

        // Write message to our subkey range
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

        // Update counter
        if (role == 'owner') {
          // Owner writes to DHT metadata
          try {
            final metaData = await rc.getDHTValue(dhtKey, 0);
            final currentMeta = metaData != null
                ? jsonDecode(utf8.decode(metaData.data)) as Map<String, dynamic>
                : <String, dynamic>{};
            currentMeta['owner_next'] = nextSubkey + 1;
            await rc.setDHTValue(
              dhtKey, 0,
              Uint8List.fromList(utf8.encode(jsonEncode(currentMeta))),
            );
          } catch (_) {}
        } else {
          // Member saves position locally
          await prefs.setInt(localCounterKey, nextSubkey + 1);
        }

        await rc.closeDHTRecord(dhtKey);

        // Mark delivered
        final idx = _conversations[recipientId]!.indexWhere((m) => m.id == message.id);
        if (idx != -1) {
          _conversations[recipientId]![idx] = message.copyWith(delivered: true);
          notifyListeners();
        }

        DebugLogService().info('Chat',' Message sent to DHT subkey $nextSubkey');
      } catch (e) {
        DebugLogService().error('Chat',' DHT write failed: $e');
      }
    }

    // Also send via relay as parallel/fallback path
    final msgPayload = jsonEncode({
      'id': message.id,
      'sender': message.senderId,
      'recipient': message.recipientId,
      'content': message.content,
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'media_refs': message.mediaRefs,
    });
    _relayService.sendViaRelay(recipientId, msgPayload);

    await _cacheMessages(recipientId);
  }

  /// Handle a message received via the relay fallback.
  void _handleRelayMessage(String contactKey, String rawMessage) {
    try {
      final msgJson = jsonDecode(rawMessage) as Map<String, dynamic>;
      final msgId = msgJson['id'] as String;

      // Skip duplicates (may already have it via DHT)
      if (_conversations[contactKey]?.any((m) => m.id == msgId) ?? false) return;

      final message = Message(
        id: msgId,
        senderId: msgJson['sender'] as String? ?? contactKey,
        recipientId: msgJson['recipient'] as String? ?? '',
        content: msgJson['content'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(msgJson['timestamp'] as int? ?? 0),
        delivered: true,
        mediaRefs: (msgJson['media_refs'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      );

      _conversations.putIfAbsent(contactKey, () => []);
      _conversations[contactKey]!.add(message);
      DebugLogService().success('Chat', 'Message received via RELAY from $contactKey');
      notifyListeners();
      _cacheMessages(contactKey);
    } catch (e) {
      DebugLogService().error('Chat', 'Relay message parse failed: $e');
    }
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
            DebugLogService().info('Chat',' Received message from $senderId');
          } catch (e) {
            DebugLogService().info('Chat',' Parse error at subkey $sk: $e');
          }
        }
      }

      await rc.closeDHTRecord(key);
      notifyListeners();
      await _cacheMessages(contactId);
    } catch (e) {
      DebugLogService().info('Chat',' Value change handling failed: $e');
    }
  }

  /// Join an existing conversation using a string key (from QR payload).
  /// Opens the record with our writer keypair so we can write to member subkeys.
  Future<void> joinConversationByString(String contactPublicKey, String dhtKeyStr, {KeyPair? writerKeypair}) async {
    _conversations.putIfAbsent(contactPublicKey, () => []);

    final rc = _veilidService?.routingContext;
    if (rc != null) {
      try {
        final dhtKey = RecordKey.fromString(dhtKeyStr);
        _conversationDhtKeys[contactPublicKey] = dhtKey;
        _conversationRoles[contactPublicKey] = 'member';

        // Open with our writer keypair so we can write to member subkeys
        if (writerKeypair != null) {
          await rc.openDHTRecord(dhtKey, writer: writerKeypair);
        } else {
          await rc.openDHTRecord(dhtKey);
        }
        await rc.watchDHTValues(dhtKey);
        await rc.closeDHTRecord(dhtKey);
        DebugLogService().info('Chat',' Joined conversation as member: $dhtKeyStr');
      } catch (e) {
        DebugLogService().info('Chat',' Failed to join by string: $e');
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
        DebugLogService().info('Chat',' Failed to watch conversation: $e');
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

  /// Delete a message locally.
  Future<void> deleteMessage(String conversationId, String messageId) async {
    final msgs = _conversations[conversationId];
    if (msgs == null) return;
    msgs.removeWhere((m) => m.id == messageId);
    await _cacheMessages(conversationId);
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
          DebugLogService().info('Chat',' TableStore load failed: $e');
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

      // Load conversation roles
      final rolesJson = prefs.getString('${_prefsConversationsKey}_roles');
      if (rolesJson != null) {
        final rolesMap = jsonDecode(rolesJson) as Map<String, dynamic>;
        rolesMap.forEach((k, v) => _conversationRoles[k] = v as String);
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
      DebugLogService().info('Chat',' Failed to load conversations: $e');
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
      DebugLogService().info('Chat',' Cache failed: $e');
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
        DebugLogService().info('Chat',' TableStore persist failed: $e');
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final keysMap = <String, String>{};
      for (final entry in _conversationDhtKeys.entries) {
        keysMap[entry.key] = entry.value.toString();
      }
      await prefs.setString(_prefsConversationsKey, jsonEncode(keysMap));
      // Also persist roles
      await prefs.setString('${_prefsConversationsKey}_roles', jsonEncode(_conversationRoles));
    } catch (e) {
      DebugLogService().info('Chat',' SharedPreferences persist failed: $e');
    }
  }
}
