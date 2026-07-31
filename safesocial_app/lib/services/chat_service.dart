import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'secure_store.dart';
import 'package:uuid/uuid.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../models/message.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'outbox_service.dart';
import 'relay_service.dart';
import 'typing_tracker.dart';

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

  final TypingTracker _typing = TypingTracker();
  Timer? _typingSweep;

  /// Whether to tell people when we are typing.
  ///
  /// A typing indicator broadcasts your activity keystroke by keystroke. Most
  /// apps make that unconditional; in one whose whole argument is not leaking
  /// behaviour it should be a choice. Default on, so it behaves as expected.
  bool _sendTypingSignals = true;
  bool get sendTypingSignals => _sendTypingSignals;

  Future<void> setSendTypingSignals(bool value) async {
    _sendTypingSignals = value;
    if (!value) _typing.clear();
    await SecureStore.instance.setBool('spheres_typing_signals', value);
    notifyListeners();
  }

  bool isTyping(String peerKey) {
    // Reciprocal, like read receipts elsewhere: if you will not say when you
    // are typing, you do not get to see when others are.
    if (!_sendTypingSignals) return false;
    return _typing.isTyping(peerKey);
  }

  /// Tell a peer we are typing, at most once every few seconds.
  Future<void> notifyTyping(String peerKey, {bool stopped = false}) async {
    if (!_sendTypingSignals) return;
    final sessions = _sessions;
    if (sessions == null) return;
    if (!_typing.shouldSend(peerKey, stopped: stopped)) return;

    try {
      final sealed = await sessions.seal(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
        type: 'typing',
        plaintext: jsonEncode({'stopped': stopped}),
        // Wrapped, not chained. A typing signal is ephemeral and deliberately
        // never retried, so letting it consume a ratchet step would punch a
        // hole in a sequence that real messages depend on — and, because it is
        // sent alongside them rather than queued behind them, would race with
        // them for the same step.
        mode: SealMode.wrap,
      );
      // Deliberately not queued in the outbox: a typing signal that arrives
      // late is worse than one that never arrives at all.
      await _relayService.sendViaRelay(peerKey, sealed);
    } catch (_) {
      // Never surface a failure for something this ephemeral.
    }
  }

  void _startTypingSweep() {
    _typingSweep?.cancel();
    // Expiry is time-based, so something has to redraw when it lapses.
    _typingSweep = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_typing.sweep()) notifyListeners();
    });
  }


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
    _startTypingSweep();
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
      String? replyToStoryId,
      String? replyToMessageId}) async {
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
      replyToMessageId: replyToMessageId,
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
    unawaited(notifyTyping(contactPublicKey, stopped: true));

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

  /// React to a message, or remove an existing reaction by sending the same
  /// emoji again.
  ///
  /// Reactions travel as their own envelope rather than as a message edit:
  /// resending the whole message would break ordering and re-notify.
  Future<void> reactToMessage(
      String peerKey, String messageId, String emoji) async {
    final sessions = _sessions;
    final me = _myPublicKey;
    if (sessions == null || me == null) return;

    final removed = _applyReaction(peerKey, messageId, me, emoji);

    try {
      final sealed = await sessions.seal(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
        type: 'chat_reaction',
        plaintext: jsonEncode({
          'message_id': messageId,
          'emoji': emoji,
          'removed': removed,
        }),
      );
      await _relayService.sendViaRelay(peerKey, sealed);
    } catch (e) {
      DebugLogService().warn('Chat', 'Could not send reaction: $e');
    }
  }

  /// Toggle a reaction locally. Returns true if it was removed.
  bool _applyReaction(
      String peerKey, String messageId, String reactorId, String emoji) {
    final messages = _conversations[peerKey];
    if (messages == null) return false;

    final index = messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return false;

    final reactions =
        List<MessageReaction>.from(messages[index].reactions);
    final existing = reactions.indexWhere(
        (r) => r.reactorId == reactorId && r.emoji == emoji);

    final removed = existing != -1;
    if (removed) {
      reactions.removeAt(existing);
    } else {
      // One reaction per person, as in every messenger people are used to.
      reactions.removeWhere((r) => r.reactorId == reactorId);
      reactions.add(MessageReaction(
          reactorId: reactorId, emoji: emoji, timestamp: DateTime.now()));
    }

    messages[index] = messages[index].copyWith(reactions: reactions);
    _persistMessages(peerKey);
    notifyListeners();
    return removed;
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

      if (opened.type == 'session_reset') {
        await _handleSessionReset(opened.from, opened.plaintext);
        return;
      }

      // Anything that opens proves the chains agree again.
      _authFailures.remove(opened.from);

      if (opened.type == 'typing') {
        final stopped = jsonDecode(opened.plaintext)['stopped'] == true;
        if (_typing.noteSignal(opened.from, stopped: stopped)) {
          notifyListeners();
        }
        return;
      }

      if (opened.type == 'chat_reaction') {
        final payload = jsonDecode(opened.plaintext);
        final messageId = payload['message_id'];
        final emoji = payload['emoji'];
        if (messageId is String && emoji is String) {
          // Attributed to the verified sender, never to a field they set.
          _applyReaction(opened.from, messageId, opened.from, emoji);
        }
        return;
      }

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
    } on SecretBoxAuthenticationError catch (_) {
      // The signature verified — so this really is from them — but the payload
      // did not authenticate. That combination means only one thing: the two
      // sides no longer agree on where the chains are.
      DebugLogService()
          .warn('Chat', 'Could not authenticate a message from $contactKey');
      await _noteAuthenticationFailure(contactKey);
    } catch (e) {
      DebugLogService().error('Chat', 'Failed to handle relay message: $e');
    }
  }

  // ── Recovering a broken session ────────────────────────────────────────────

  /// Failures in a row, per peer. Reset by anything that decrypts.
  final Map<String, int> _authFailures = {};

  /// When we last restarted a session with each peer.
  final Map<String, DateTime> _lastReset = {};

  /// How many failures in a row before concluding the chains have diverged.
  ///
  /// More than one, because a single failure can be a corrupted delivery. Not
  /// many more, because until this fires the conversation is dead.
  static const int resetAfterFailures = 3;

  /// Floor on how often a session may restart.
  ///
  /// A restart throws away anything in flight, so a fault that keeps recurring
  /// must not turn into a loop that destroys every message that follows.
  static const Duration resetCooldown = Duration(minutes: 5);

  /// Peers whose session was restarted recently, so the UI can say so.
  final Set<String> _recentlyReset = {};

  bool wasRecentlyReset(String peerKey) => _recentlyReset.contains(peerKey);

  void acknowledgeReset(String peerKey) {
    if (_recentlyReset.remove(peerKey)) notifyListeners();
  }

  Future<void> _noteAuthenticationFailure(String peerKey) async {
    final count = (_authFailures[peerKey] ?? 0) + 1;
    _authFailures[peerKey] = count;
    if (count < resetAfterFailures) return;

    final last = _lastReset[peerKey];
    if (last != null && DateTime.now().difference(last) < resetCooldown) {
      DebugLogService().warn('Chat',
          'Session with $peerKey still failing, but it was just restarted');
      return;
    }

    await _restartSession(peerKey, announce: true);
  }

  /// Restart a session because the user asked, not because we detected a fault.
  ///
  /// Bypasses the failure counter — they are telling us it is broken — but not
  /// the cooldown, so repeated taps cannot shred whatever is still in flight.
  Future<void> restartSessionManually(String peerKey) async {
    final last = _lastReset[peerKey];
    if (last != null && DateTime.now().difference(last) < resetCooldown) {
      throw StateError(
        'This session was just re-established. Give it a minute before '
        'trying again.',
      );
    }
    await _restartSession(peerKey, announce: true);
  }

  Future<void> _restartSession(String peerKey, {required bool announce}) async {
    final sessions = _sessions;
    if (sessions == null) return;

    try {
      final epoch = await sessions.beginReset(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
      );
      await _afterReset(peerKey, epoch);
      if (announce) await _announceReset(peerKey, epoch);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not restart the session: $e');
    }
  }

  /// Tell the peer which epoch we have moved to.
  ///
  /// Wrapped rather than chained, because the chain is the broken thing — a
  /// request to fix it cannot depend on it working.
  Future<void> _announceReset(String peerKey, int epoch) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final sealed = await sessions.seal(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
        type: 'session_reset',
        plaintext: jsonEncode({'epoch': epoch}),
        mode: SealMode.wrap,
      );
      await _relayService.sendViaRelay(peerKey, sealed);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not announce the restart: $e');
    }
  }

  Future<void> _afterReset(String peerKey, int epoch) async {
    _authFailures.remove(peerKey);
    _lastReset[peerKey] = DateTime.now();
    _recentlyReset.add(peerKey);

    // Anything queued was sealed under the chain we just abandoned, and the
    // outbox holds only ciphertext, so it can never be re-sealed. Failing it
    // is honest; leaving it to retry forever would not be.
    final stranded = await _outbox?.failPendingForPeer(peerKey) ?? 0;
    DebugLogService().warn(
      'Chat',
      'Restarted the session with $peerKey at epoch $epoch'
      '${stranded == 0 ? '' : '; $stranded queued message'
          '${stranded == 1 ? '' : 's'} could not be recovered'}',
    );
    notifyListeners();
  }

  Future<void> _handleSessionReset(String peerKey, String payload) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final epoch = jsonDecode(payload)['epoch'];
      if (epoch is! int || epoch < 1) return;

      final changed = await sessions.adoptReset(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(peerKey),
        epoch: epoch,
      );
      if (!changed) return;

      await _afterReset(peerKey, epoch);
      // Echo it back so a peer that has not caught up converges too. Adopting
      // is idempotent, so this cannot bounce.
      await _announceReset(peerKey, epoch);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not apply a session restart: $e');
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

  @override
  void dispose() {
    _typingSweep?.cancel();
    super.dispose();
  }

  Future<void> loadConversations() async {
    _sendTypingSignals =
        await SecureStore.instance.getBool('spheres_typing_signals') ?? true;

    final prefs = SecureStore.instance;
    final keysJson = await prefs.getString(_prefsConversationsKey);
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
    final prefs = SecureStore.instance;
    final msgsJson = await prefs.getString('$_prefsMsgPrefix$contactKey');
    if (msgsJson != null) {
      final List<dynamic> msgs = jsonDecode(msgsJson);
      _conversations[contactKey] = msgs.map((m) => Message.fromJson(m)).toList();
    }
  }

  Future<void> _persistMessages(String contactKey) async {
    final prefs = SecureStore.instance;
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
    final prefs = SecureStore.instance;
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
    final prefs = SecureStore.instance;
    final keys = _conversations.keys.toList();
    await prefs.setString(_prefsConversationsKey, jsonEncode(Map.fromIterable(keys)));
  }

  Future<void> createConversation(String contactPublicKey) async {
    _conversations.putIfAbsent(contactPublicKey, () => []);
    notifyListeners();
  }
}
