import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../models/message.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'outbox_service.dart';
import 'relay_service.dart';

/// Manages chat conversations over the relay.
///
/// Messages are sealed with [SealMode.chain]: each one uses a fresh ratcheted
/// key, and the sender is proven by an Ed25519 signature over the envelope
/// header rather than taken from a self-declared field.
class ChatService extends ChangeNotifier {
  static const _prefsConversationsKey = 'spheres_conversations';
  static const _prefsMsgPrefix = 'spheres_msgs_';

  final RelayService _relayService = RelayService();
  SessionManager? _sessions;
  OutboxService? _outbox;

  /// Resolves a contact's X25519 public key by their identity key. Supplied by
  /// the app so ChatService does not need to depend on ContactService.
  String? Function(String identityKey)? _resolveExchangeKey;

  String? _myPublicKey;

  final Map<String, List<Message>> _conversations = {};
  String? _activeConversation;

  Map<String, List<Message>> get conversations => Map.unmodifiable(_conversations);
  String? get activeConversation => _activeConversation;


  void setActiveConversation(String? conversationId) {
    _activeConversation = conversationId;
    notifyListeners();
  }

  void setMyInfo(
    String publicKey,
    String secretKey, {
    SessionManager? sessions,
    OutboxService? outbox,
    String? Function(String identityKey)? resolveExchangeKey,
  }) {
    _myPublicKey = publicKey;
    if (sessions != null) _sessions = sessions;
    if (resolveExchangeKey != null) _resolveExchangeKey = resolveExchangeKey;

    if (outbox != null) {
      _outbox = outbox;
      outbox.send = _relayService.sendViaRelay;
      // Retry as soon as a room comes back, rather than waiting for the tick.
      _relayService.onConnected = (peer) => outbox.flush(onlyPeer: peer);
    }

    _relayService.onMessageReceived = (contactKey, raw) {
      _handleRelayMessage(contactKey, raw);
    };
  }

  /// Called with (senderIdentityKey, payload) for verified `sphere_op`
  /// envelopes. Set by the app so ChatService need not know about spheres.
  Future<void> Function(String from, String payload)? onSphereOp;

  /// Send an already-sealed payload straight to a peer.
  ///
  /// Used for control traffic (sphere membership, key distribution) that has
  /// its own sealing and must not be queued as a chat message.
  Future<bool> sendRawToPeer(String peerIdentityKey, String payload) =>
      _relayService.sendViaRelay(peerIdentityKey, payload);

  /// Delivery state for a message we sent, or null if it is not tracked.
  OutboxState? deliveryState(String messageId) => _outbox?.stateOf(messageId);

  /// Open the chat channel with a contact.
  ///
  /// The address is derived from the pairwise secret, so the relay cannot tell
  /// which two identities it belongs to.
  Future<void> connectRelay(String contactPublicKey) async {
    final sessions = _sessions;
    if (_myPublicKey == null || sessions == null) return;
    try {
      final mailbox = await sessions.mailboxFor(
        peerIdentityKey: contactPublicKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(contactPublicKey),
        purpose: 'chat',
      );
      await _relayService.connectMailbox(contactPublicKey, mailbox);
    } on NoSessionException {
      // No key exchange key yet — the channel opens once a handshake or prekey
      // fetch supplies one. Staying disconnected is correct; there is nobody
      // we could safely talk to.
      DebugLogService().info(
          'Chat', 'Waiting for $contactPublicKey to publish an encryption key');
    }
  }

  bool isRelayConnected(String contactPublicKey) => _relayService.isConnected(contactPublicKey);

  List<String> getConversationIds() => _conversations.keys.toList();

  /// Send a message to a contact.
  ///
  /// Throws [NoSessionException] when the contact's key exchange key is not
  /// known yet. The message is not stored locally in that case — showing it as
  /// sent when it was never encrypted or delivered is what made the old
  /// behaviour misleading.
  Future<void> sendMessage(String contactPublicKey, String content,
      {List<String>? mediaRefs,
      String? audioRef,
      String? replyToStoryId}) async {
    final sessions = _sessions;
    if (sessions == null || !sessions.isReady) {
      throw StateError('ChatService has no identity yet');
    }

    final message = Message(
      id: const Uuid().v4(),
      senderId: _myPublicKey!,
      recipientId: contactPublicKey,
      content: content,
      timestamp: DateTime.now(),
      mediaRefs: mediaRefs ?? [],
      audioRef: audioRef,
      replyToStoryId: replyToStoryId,
    );

    // Send the image itself, not a path into our own sandbox. Chat previously
    // serialised mediaRefs as local filesystem paths, so a photo sent to a
    // contact arrived as a dead reference they could never open.
    final wireMessage = await _encodeMedia(message);

    final sealed = await sessions.seal(
      peerIdentityKey: contactPublicKey,
      peerKeyExchangePublicKey: _resolveExchangeKey?.call(contactPublicKey),
      type: 'chat',
      plaintext: jsonEncode(wireMessage.toJson()),
    );

    // Keep the local copy pointing at the local file.
    _addMessageLocally(contactPublicKey, message);

    // Durable hand-off. If the socket is down the message waits here and is
    // retried on reconnect or on the next tick — including across app restarts.
    final outbox = _outbox;
    if (outbox != null) {
      await outbox.enqueue(
        id: message.id,
        peer: contactPublicKey,
        payload: sealed,
      );
    } else {
      await _relayService.sendViaRelay(contactPublicKey, sealed);
    }
  }

  /// Swap local media paths for transferable data before sending.
  Future<Message> _encodeMedia(Message message) async {
    if (message.mediaRefs.isEmpty) return message;

    final encoded = <String>[];
    for (final ref in message.mediaRefs) {
      final data = await MediaService.encodeImageForRelay(ref);
      if (data != null) encoded.add(data);
    }
    return message.copyWith(mediaRefs: encoded);
  }

  /// Turn received media back into files on this device.
  Future<Message> _decodeMedia(Message message) async {
    if (message.mediaRefs.isEmpty) return message;

    final saved = <String>[];
    for (final ref in message.mediaRefs) {
      final path = await MediaService.decodeAndSaveImage(ref);
      saved.add(path ?? ref);
    }
    return message.copyWith(mediaRefs: saved);
  }

  /// Tell a sender we have their message, so their copy stops showing as unsent.
  Future<void> _sendReceipt(String peerKey, String messageId) async {
    final sessions = _sessions;
    if (sessions == null || !sessions.isReady) return;
    try {
      final sealed = await sessions.seal(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
        type: 'receipt',
        plaintext: jsonEncode({'id': messageId}),
      );
      await _relayService.sendViaRelay(peerKey, sealed);
    } catch (e) {
      // A receipt is best-effort; never let it break message handling.
      DebugLogService().warn('Chat', 'Could not send receipt: $e');
    }
  }

  Future<void> _handleRelayMessage(String contactKey, String raw) async {
    final sessions = _sessions;
    if (sessions == null) return;

    try {
      final opened = await sessions.open(
        raw: raw,
        resolveExchangeKey: (key) => _resolveExchangeKey?.call(key),
      );

      if (opened.type == 'receipt') {
        final id = jsonDecode(opened.plaintext)['id'];
        if (id is String) await _outbox?.markDelivered(id);
        return;
      }

      if (opened.type == 'sphere_op') {
        await onSphereOp?.call(opened.from, opened.plaintext);
        return;
      }

      if (opened.type != 'chat') {
        DebugLogService()
            .warn('Chat', 'Ignoring envelope of type "${opened.type}"');
        return;
      }

      final msg = Message.fromJson(jsonDecode(opened.plaintext));

      // Authorship comes from the verified signature, not the payload. A peer
      // cannot attribute a message to someone else by setting senderId.
      if (msg.senderId != opened.from) {
        DebugLogService().warn(
          'Chat',
          'Dropping message: payload claims ${msg.senderId} but it is signed by ${opened.from}',
        );
        return;
      }

      _addMessageLocally(opened.from, await _decodeMedia(msg));
      await _sendReceipt(opened.from, msg.id);
    } on EnvelopeException catch (e) {
      DebugLogService().error('Chat', 'Rejected message from $contactKey: $e');
    } on NoSessionException catch (e) {
      DebugLogService().warn('Chat', 'Cannot decrypt yet: $e');
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

  Future<void> removeConversation(String contactKey) async {
    _conversations.remove(contactKey);
    _sessions?.forget(contactKey);

    // Actually delete the stored messages. Previously only the index entry was
    // removed, leaving the message history readable on disk indefinitely.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefsMsgPrefix$contactKey');
    await _outbox?.removeForPeer(contactKey);

    await _persistConversationKeys();
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
