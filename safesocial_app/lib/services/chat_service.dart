import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'secure_store.dart';
import 'package:uuid/uuid.dart';

import '../crypto/blob.dart';
import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../models/media_provenance.dart';
import '../models/message.dart';
import 'debug_log_service.dart';
import 'inbound_events.dart';
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
    if (isIgnored?.call(peerKey) ?? false) return;
    final sessions = _sessions;
    if (sessions == null) return;
    if (!_typing.shouldSend(peerKey, stopped: stopped)) return;

    try {
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: peerKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(peerKey),
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
      await _relayService.sendSealed(peerKey, sealed);
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
    // Leaving a chat stamps it too: everything that arrived while it was on
    // screen was seen, and the stamp from opening it would count all of
    // that as unread after a restart.
    final previous = _activeConversation;
    if (previous != null && previous != conversationId) _stampOpened(previous);
    _activeConversation = conversationId;
    if (conversationId != null) {
      _stampOpened(conversationId);
      unawaited(markRead(conversationId));
    }
    notifyListeners();
  }

  void _stampOpened(String conversationId) {
    _lastOpened[conversationId] = DateTime.now();
    SecureStore.instance.setString(_lastOpenedKey,
        jsonEncode(_lastOpened.map((k, v) => MapEntry(k, v.toIso8601String()))));
  }

  static const _lastOpenedKey = 'spheres_chat_last_opened_v1';
  final Map<String, DateTime> _lastOpened = {};

  /// Inbound messages since the chat was last on screen.
  int unreadCount(String contactKey) {
    if (_activeConversation == contactKey) return 0;
    final since = _lastOpened[contactKey];
    return (_conversations[contactKey] ?? const <Message>[])
        .where((m) => m.senderId != _myPublicKey && !m.isSystem &&
            (since == null || m.timestamp.isAfter(since)))
        .length;
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
      outbox.send = (peer, payload, {deviceKey}) =>
          _relayService.sendViaRelay(peer, payload, deviceKey: deviceKey);
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

  /// Send an already-sealed payload straight to a peer device.
  ///
  /// Used for control traffic (sphere membership, key distribution) that has
  /// its own sealing and must not be queued as a chat message. Our own
  /// identity key as [peerIdentityKey] reaches our other devices.
  Future<bool> sendRawToPeer(String peerIdentityKey, String payload,
          {String? deviceKey}) =>
      _relayService.sendViaRelay(peerIdentityKey, payload, deviceKey: deviceKey);

  /// Seal [plaintext] for every other device of ours and send it. Nothing
  /// happens when this is our only device.
  Future<void> sendToOwnDevices(String type, String plaintext,
      {SealMode mode = SealMode.wrap}) async {
    final sessions = _sessions;
    final me = _myPublicKey;
    if (sessions == null || me == null) return;
    try {
      final sealed = await sessions.sealForOwnDevices(
          type: type, plaintext: plaintext, mode: mode);
      if (sealed.isEmpty) {
        DebugLogService().info('Chat', 'No other devices to tell about $type');
        return;
      }
      final ok = await _relayService.sendSealed(me, sealed);
      DebugLogService().info('Chat',
          '${ok ? 'Told' : 'Could not tell'} ${sealed.length} other device(s) about $type');
    } catch (e) {
      DebugLogService().warn('Chat', 'Could not reach our other devices: $e');
    }
  }

  /// Every contact we could seal to. Set by the app; without it only peers
  /// with an open conversation are told about device changes.
  List<String> Function()? contactKeys;

  /// Tell every contact, and our other devices, which devices we now use.
  ///
  /// Goes to every contact, not only those with a conversation: a contact who
  /// has never written to us still seals to our device list, and a stale one
  /// sends their first message to a key nobody holds.
  Future<void> broadcastDeviceList(Map<String, dynamic> listJson) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final payload = jsonEncode({'devices': listJson});
    final peers = {...?contactKeys?.call(), ..._conversations.keys};
    for (final peer in peers.toList()) {
      if (peer == _myPublicKey) continue;
      try {
        final sealed = await sessions.sealForDevices(
          peerIdentityKey: peer,
          fallbackExchangeKey: _resolveExchangeKey?.call(peer),
          type: 'devices',
          plaintext: payload,
          mode: SealMode.wrap,
        );
        await _relayService.sendSealed(peer, sealed);
      } catch (_) {
        // They will see the bundle on their next refresh.
      }
    }
    await sendToOwnDevices('devices', payload);
  }

  /// A contact's (or our own) new signed device list arrived.
  Future<void> Function(String from, Object? listJson)? onDeviceList;

  /// A contact sent their profile as they let us see it: name, picture, and
  /// whatever fields our shared spheres put us in the audience for.
  Future<void> Function(String from, Map<String, dynamic> profile)? onProfile;

  /// One of our own other devices changed our profile; adopt it here.
  Future<void> Function(Map<String, dynamic> profile)? onOwnProfile;

  /// Tell every contact, and our other devices, how we look now. Wrapped, so
  /// it never consumes a ratchet step.
  ///
  /// Each contact gets their own copy from [payloadFor], because fields have
  /// audiences: what one person may see another may not. [everything] is
  /// what our other devices get, which is all of it.
  Future<void> broadcastProfile(
    Map<String, dynamic> Function(String peer) payloadFor, {
    Map<String, dynamic>? everything,
  }) async {
    final sessions = _sessions;
    if (sessions == null) return;
    for (final peer in _conversations.keys.toList()) {
      if (peer == _myPublicKey) continue;
      try {
        final sealed = await sessions.sealForDevices(
          peerIdentityKey: peer,
          fallbackExchangeKey: _resolveExchangeKey?.call(peer),
          type: 'profile',
          plaintext: jsonEncode(payloadFor(peer)),
          mode: SealMode.wrap,
        );
        await _relayService.sendSealed(peer, sealed);
      } catch (_) {}
    }
    final me = _myPublicKey;
    await sendToOwnDevices(
        'profile', jsonEncode(everything ?? (me == null ? {} : payloadFor(me))));
  }

  /// A contact-list change from one of our other devices.
  Future<void> Function(Map<String, dynamic> op)? onContactSync;

  /// A known contact wrote from a device we have not been told about. The app
  /// refreshes their bundle; the envelope is retried once that returns.
  Future<bool> Function(String identityKey)? onUnknownDevice;
  final Map<String, List<String>> _awaitingDevice = {};

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
      final devices = sessions.devicesOf(contactPublicKey,
          fallback: _resolveExchangeKey?.call(contactPublicKey));
      if (devices.isEmpty) throw NoSessionException(contactPublicKey);
      for (final device in devices) {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: contactPublicKey,
          peerKeyExchangePublicKey: device,
          purpose: 'chat',
        );
        await _relayService.connectMailbox(contactPublicKey, mailbox,
            deviceKey: device);
      }
    } on NoSessionException {
      // No key exchange key yet — the channel opens once a handshake or prekey
      // fetch supplies one. Staying disconnected is correct; there is nobody
      // we could safely talk to.
      DebugLogService().info(
          'Chat', 'Waiting for $contactPublicKey to publish an encryption key');
    }
  }

  bool isRelayConnected(String contactPublicKey) => _relayService.isConnected(contactPublicKey);

  /// Open the channel to each of our other devices, so what we send and what
  /// they send shows up everywhere. Safe to call again when the list changes.
  Future<void> connectOwnDevices() async {
    final sessions = _sessions;
    final me = _myPublicKey;
    if (sessions == null || me == null) return;
    final others = sessions.devicesOf(me);
    DebugLogService().info('Chat',
        others.isEmpty
            ? 'No other devices of ours to listen for'
            : 'Listening for ${others.length} other device(s) of ours');
    for (final device in others) {
      try {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: me,
          peerKeyExchangePublicKey: device,
          purpose: 'chat',
        );
        await _relayService.connectMailbox(me, mailbox, deviceKey: device);
      } catch (e) {
        DebugLogService().warn('Chat', 'Could not open a channel to our own device: $e');
      }
    }
  }

  List<String> getConversationIds() => _conversations.keys.toList();

  /// Send a message to a contact.
  ///
  /// Throws [NoSessionException] when the contact's key exchange key is not
  /// known yet. The message is not stored locally in that case — showing it as
  /// sent when it was never encrypted or delivered is what made the old
  /// behaviour misleading.
  Future<Message> sendMessage(String contactPublicKey, String content,
      {List<String>? mediaRefs,
      String? audioRef,
      String? replyToStoryId,
      String? replyToMessageId,
      String kind = 'text',
      Map<String, dynamic>? payload,
      bool viewOnce = false,
      bool forwarded = false,
      List<MediaProvenance?>? provenance}) async {
    final sessions = _sessions;
    if (sessions == null || !sessions.isReady) {
      throw StateError('ChatService has no identity yet');
    }

    final ttl = disappearAfter(contactPublicKey);
    final message = Message(
      id: const Uuid().v4(),
      senderId: _myPublicKey!,
      recipientId: contactPublicKey,
      content: content,
      timestamp: DateTime.now(),
      mediaRefs: mediaRefs ?? [],
      provenance: provenance ?? MediaService.provenanceListFor(mediaRefs ?? []),
      audioRef: audioRef,
      replyToStoryId: replyToStoryId,
      replyToMessageId: replyToMessageId,
      kind: kind,
      payload: payload,
      viewOnce: viewOnce,
      forwarded: forwarded,
      // Carried in the message, so both sides delete on the same schedule.
      expiresAt: ttl == null ? null : DateTime.now().add(ttl),
    );

    // Send the image itself, not a path into our own sandbox. Chat previously
    // serialised mediaRefs as local filesystem paths, so a photo sent to a
    // contact arrived as a dead reference they could never open.
    final wireMessage = await _encodeMedia(message);

    final plaintext = jsonEncode(wireMessage.toJson());
    final sealed = await sessions.sealForDevices(
      peerIdentityKey: contactPublicKey,
      fallbackExchangeKey: _resolveExchangeKey?.call(contactPublicKey),
      type: 'chat',
      plaintext: plaintext,
    );
    // Our other devices get a copy too, so the conversation reads the same
    // on every phone we own.
    final own = await sessions.sealForOwnDevices(type: 'chat', plaintext: plaintext);

    // Keep the local copy pointing at the local file.
    _addMessageLocally(contactPublicKey, message);
    unawaited(notifyTyping(contactPublicKey, stopped: true));

    // Durable hand-off. If the socket is down the message waits here and is
    // retried on reconnect or on the next tick — including across app restarts.
    final outbox = _outbox;
    if (outbox != null) {
      await outbox.enqueueAll(
        id: message.id,
        peer: contactPublicKey,
        payloads: {for (final s in sealed) s.deviceKey: s.sealed},
      );
      if (own.isNotEmpty) {
        await outbox.enqueueAll(
          id: '${message.id}:self',
          peer: _myPublicKey!,
          payloads: {for (final s in own) s.deviceKey: s.sealed},
        );
      }
    } else {
      await _relayService.sendSealed(contactPublicKey, sealed);
      if (own.isNotEmpty) await _relayService.sendSealed(_myPublicKey!, own);
    }
    return message;
  }

  // ── Conversation-level settings ───────────────────────────────────────────

  static const _settingsKey = 'spheres_chat_settings_v1';
  static const _pinsKey = 'spheres_chat_pins_v1';
  static const _readReceiptsKey = 'spheres_read_receipts';

  /// Disappearing-message timer per conversation, in seconds. Either side may
  /// set it; the change is itself a message so both agree.
  final Map<String, int> _disappear = {};

  Duration? disappearAfter(String contactKey) {
    final seconds = _disappear[contactKey];
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  Future<void> setDisappearing(String contactKey, Duration? after) async {
    final seconds = after?.inSeconds ?? 0;
    if ((_disappear[contactKey] ?? 0) == seconds) return;
    await _applyDisappearing(contactKey, seconds, by: _myPublicKey!);
    await _sendControl(contactKey, 'chat_settings',
        {'disappear_seconds': seconds, 'peer': contactKey});
  }

  Future<void> _applyDisappearing(String contactKey, int seconds,
      {required String by}) async {
    if (seconds <= 0) {
      _disappear.remove(contactKey);
    } else {
      _disappear[contactKey] = seconds;
    }
    await SecureStore.instance.setString(_settingsKey, jsonEncode(_disappear));
    final who = by == _myPublicKey ? 'You' : (resolveName?.call(by) ?? 'They');
    _addMessageLocally(
      contactKey,
      Message(
        id: const Uuid().v4(),
        senderId: by,
        recipientId: contactKey,
        content: seconds <= 0
            ? '$who turned off disappearing messages.'
            : '$who set messages to disappear after ${describeDuration(Duration(seconds: seconds))}.',
        timestamp: DateTime.now(),
        kind: 'system',
      ),
      notify: false,
    );
  }

  static String describeDuration(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
    if (d.inHours >= 1) return '${d.inHours} hour${d.inHours == 1 ? '' : 's'}';
    return '${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'}';
  }

  /// Drop every message whose time is up. Runs on load and on a timer.
  Future<void> sweepExpired() async {
    var changed = false;
    for (final entry in _conversations.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((m) => m.isExpired);
      if (entry.value.length != before) {
        changed = true;
        await _persistMessages(entry.key);
      }
    }
    if (changed) notifyListeners();
  }

  Timer? _expirySweep;
  void _startExpirySweep() {
    _expirySweep?.cancel();
    _expirySweep = Timer.periodic(const Duration(seconds: 30), (_) {
      sweepExpired();
      sendDueScheduled();
    });
  }

  /// Send a small control payload to every device of a peer and our own.
  Future<void> _sendControl(String contactKey, String type, Map<String, dynamic> body,
      {SealMode mode = SealMode.chain}) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final plaintext = jsonEncode(body);
    try {
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: contactKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(contactKey),
        type: type,
        plaintext: plaintext,
        mode: mode,
      );
      await _relayService.sendSealed(contactKey, sealed);
    } catch (e) {
      DebugLogService().warn('Chat', 'Could not send $type: $e');
    }
    await sendToOwnDevices(type, plaintext, mode: mode);
  }

  // ── Edit, delete for everyone, forward ────────────────────────────────────

  /// How long after sending a message may still be edited or unsent.
  static const Duration editWindow = Duration(minutes: 15);

  Message? _find(String contactKey, String messageId) {
    for (final m in _conversations[contactKey] ?? const <Message>[]) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  Future<void> editMessage(String contactKey, String messageId, String text) async {
    final msg = _find(contactKey, messageId);
    if (msg == null || msg.senderId != _myPublicKey) {
      throw StateError('Only your own messages can be edited');
    }
    if (DateTime.now().difference(msg.timestamp) > editWindow) {
      throw StateError('Messages can be edited for ${editWindow.inMinutes} minutes after sending');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == msg.content) return;
    final at = DateTime.now();
    _replace(contactKey, msg.copyWith(content: trimmed, editedAt: at));
    await _sendControl(contactKey, 'chat_edit',
        {'message_id': messageId, 'content': trimmed, 'edited_at': at.toIso8601String(), 'peer': contactKey});
  }

  Future<void> deleteForEveryone(String contactKey, String messageId) async {
    final msg = _find(contactKey, messageId);
    if (msg == null || msg.senderId != _myPublicKey) {
      throw StateError('Only your own messages can be unsent');
    }
    _replace(contactKey, _tombstone(msg));
    await _sendControl(contactKey, 'chat_delete', {'message_id': messageId, 'peer': contactKey});
  }

  Message _tombstone(Message m) => Message(
        id: m.id,
        senderId: m.senderId,
        recipientId: m.recipientId,
        content: '',
        timestamp: m.timestamp,
        delivered: m.delivered,
        deletedAt: DateTime.now(),
        replyToMessageId: m.replyToMessageId,
        readBy: m.readBy,
      );

  void _replace(String contactKey, Message updated) {
    final list = _conversations[contactKey];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == updated.id);
    if (index == -1) return;
    list[index] = updated;
    _persistMessages(contactKey);
    notifyListeners();
  }

  /// Send a copy of a message into another conversation.
  Future<Message> forwardMessage(String toContactKey, Message source) =>
      sendMessage(
        toContactKey,
        source.content,
        mediaRefs: source.mediaRefs,
        provenance: source.provenance,
        audioRef: source.audioRef,
        kind: source.isPoll ? 'poll' : source.kind,
        // A forwarded poll starts fresh; the original's votes stay with it.
        payload: source.isPoll
            ? (Map<String, dynamic>.from(source.payload ?? {})..remove('votes'))
            : source.payload,
        forwarded: true,
      );

  // ── Pinned message ────────────────────────────────────────────────────────

  final Map<String, String> _pins = {};

  String? pinnedMessageId(String contactKey) => _pins[contactKey];

  Future<void> pinMessage(String contactKey, String? messageId) async {
    _applyPin(contactKey, messageId);
    await _sendControl(contactKey, 'chat_pin', {'message_id': messageId, 'peer': contactKey});
  }

  void _applyPin(String contactKey, String? messageId) {
    if (messageId == null) {
      _pins.remove(contactKey);
    } else {
      _pins[contactKey] = messageId;
    }
    SecureStore.instance.setString(_pinsKey, jsonEncode(_pins));
    notifyListeners();
  }

  // ── Read receipts ─────────────────────────────────────────────────────────

  bool _sendReadReceipts = true;
  bool get sendReadReceipts => _sendReadReceipts;

  Future<void> setSendReadReceipts(bool value) async {
    _sendReadReceipts = value;
    await SecureStore.instance.setBool(_readReceiptsKey, value);
    notifyListeners();
  }

  /// Whether the peer has read one of our messages. Reciprocal: if you do not
  /// send receipts, you do not see them.
  bool isReadByPeer(String contactKey, Message m) =>
      _sendReadReceipts && m.readBy.contains(contactKey);

  final Set<String> _readSent = {};

  /// The conversation is on screen: tell the sender we have read what is
  /// there. Called when a chat opens and when a message arrives while open.
  Future<void> markRead(String contactKey) async {
    if (!_sendReadReceipts) return;
    if (isIgnored?.call(contactKey) ?? false) return;
    final unread = (_conversations[contactKey] ?? const <Message>[])
        .where((m) => m.senderId != _myPublicKey && !m.isSystem && !_readSent.contains(m.id))
        .map((m) => m.id)
        .toList();
    if (unread.isEmpty) return;
    _readSent.addAll(unread);
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: contactKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(contactKey),
        type: 'read',
        plaintext: jsonEncode({'ids': unread}),
        mode: SealMode.wrap,
      );
      await _relayService.sendSealed(contactKey, sealed);
    } catch (_) {}
  }

  // ── Polls ─────────────────────────────────────────────────────────────────

  /// Ask a question. [options] are the choices; [multiple] allows more than
  /// one; [anonymous] records votes under a per-poll hash of the voter.
  Future<Message> sendPoll(
    String contactKey,
    String question,
    List<String> options, {
    bool multiple = false,
    bool anonymous = false,
  }) =>
      sendMessage(contactKey, question, kind: 'poll', payload: {
        'question': question,
        'options': options,
        'multiple': multiple,
        'anonymous': anonymous,
        'votes': <String, dynamic>{},
      });

  Future<void> votePoll(String contactKey, String messageId, List<int> choices) async {
    final msg = _find(contactKey, messageId);
    if (msg == null || !msg.isPoll) return;
    _applyVote(contactKey, msg, _myPublicKey!, choices);
    await _sendControl(contactKey, 'poll_vote',
        {'message_id': messageId, 'choices': choices, 'peer': contactKey});
  }

  void _applyVote(String contactKey, Message poll, String voter, List<int> choices) {
    final payload = Map<String, dynamic>.from(poll.payload ?? {});
    final options = (payload['options'] as List?)?.length ?? 0;
    final multiple = payload['multiple'] == true;
    var valid = choices.where((c) => c >= 0 && c < options).toSet().toList()..sort();
    if (!multiple && valid.length > 1) valid = [valid.first];
    final votes = Map<String, dynamic>.from(payload['votes'] as Map? ?? {});
    final key = payload['anonymous'] == true ? voterHash(voter, poll.id) : voter;
    if (valid.isEmpty) {
      votes.remove(key);
    } else {
      votes[key] = valid;
    }
    payload['votes'] = votes;
    _replace(contactKey, poll.copyWith(payload: payload));
  }

  /// Anonymous polls still need one vote per person; a hash keyed by the poll
  /// gives that without naming the voter.
  static String voterHash(String voter, String pollId) =>
      base64Url.encode(utf8.encode('$pollId|$voter').sublist(0, 12)) + voter.hashCode.toRadixString(36);

  // ── Live location ─────────────────────────────────────────────────────────

  /// Supplies the current position; replaceable for tests and platforms
  /// without a location service.
  Future<({double lat, double lng})?> Function()? positionProvider;

  final Map<String, Timer> _liveLocation = {};

  /// Share where we are for [duration], updating every half minute. The
  /// positions travel sealed like any message; the relay sees nothing.
  Future<Message?> startLiveLocation(String contactKey, Duration duration) async {
    final provider = positionProvider;
    if (provider == null) throw StateError('Location is not available on this device');
    final pos = await provider();
    if (pos == null) throw StateError('Could not get a location fix');
    final until = DateTime.now().add(duration);
    final msg = await sendMessage(contactKey, 'Live location', kind: 'location', payload: {
      'lat': pos.lat,
      'lng': pos.lng,
      'live': true,
      'until': until.toIso8601String(),
      'updated': DateTime.now().toIso8601String(),
    });
    _liveLocation[msg.id]?.cancel();
    _liveLocation[msg.id] = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (DateTime.now().isAfter(until)) {
        t.cancel();
        _liveLocation.remove(msg.id);
        return;
      }
      final p = await provider();
      if (p == null) return;
      final payload = {
        'message_id': msg.id,
        'lat': p.lat,
        'lng': p.lng,
        'updated': DateTime.now().toIso8601String(),
        'peer': contactKey,
      };
      _applyLocationUpdate(contactKey, payload);
      await _sendControl(contactKey, 'location_update', payload, mode: SealMode.wrap);
    });
    return msg;
  }

  Future<void> stopLiveLocation(String contactKey, String messageId) async {
    _liveLocation.remove(messageId)?.cancel();
    final payload = {
      'message_id': messageId,
      'until': DateTime.now().toIso8601String(),
      'peer': contactKey,
    };
    _applyLocationUpdate(contactKey, payload);
    await _sendControl(contactKey, 'location_update', payload, mode: SealMode.wrap);
  }

  void _applyLocationUpdate(String contactKey, Map<String, dynamic> update) {
    final id = update['message_id'];
    if (id is! String) return;
    final msg = _find(contactKey, id);
    if (msg == null || !msg.isLocation) return;
    final payload = Map<String, dynamic>.from(msg.payload ?? {});
    for (final k in ['lat', 'lng', 'updated', 'until']) {
      if (update[k] != null) payload[k] = update[k];
    }
    _replace(contactKey, msg.copyWith(payload: payload));
  }

  /// Share a contact into a chat. Their key and name only; the recipient still
  /// has to ask them, and they still have to say yes.
  Future<Message> sendContactCard(String contactKey, Map<String, dynamic> card) =>
      sendMessage(contactKey, card['name'] as String? ?? 'Contact', kind: 'contact', payload: card);

  // ── View once ─────────────────────────────────────────────────────────────

  /// The viewer opened a view-once item: drop it here for good.
  Future<void> consumeViewOnce(String contactKey, String messageId) async {
    final msg = _find(contactKey, messageId);
    if (msg == null || !msg.viewOnce) return;
    _replace(contactKey, msg.copyWith(mediaRefs: const [], payload: {'consumed': true}));
  }

  // ── Export ────────────────────────────────────────────────────────────────

  /// The conversation as plain text, oldest first.
  String exportConversation(String contactKey, String Function(String key) nameFor) {
    final lines = <String>[];
    for (final m in _conversations[contactKey] ?? const <Message>[]) {
      final who = nameFor(m.senderId);
      final when = m.timestamp.toLocal().toString().substring(0, 16);
      final body = m.isDeleted
          ? '[deleted]'
          : (m.content.isNotEmpty ? m.content : describeMessage(m));
      lines.add('[$when] $who: $body');
    }
    return lines.join('\n');
  }

  /// Swap local media paths for transferable data before sending.
  Future<Message> _encodeMedia(Message message) async {
    // A voice note is a local recording until it is uploaded; sending the
    // path meant the other side got a reference into our sandbox and a
    // player that could do nothing with it.
    String? audio = message.audioRef;
    if (audio != null && BlobRef.tryDecode(audio) == null) {
      audio = await MediaService.prepareAudioForRelay(audio);
      if (audio == null) {
        throw const MediaRejectedException(
            'The voice note could not be uploaded. Try again.');
      }
    }
    if (message.mediaRefs.isEmpty) {
      return audio == message.audioRef ? message : message.copyWith(audioRef: audio);
    }

    final encoded = <String>[];
    final provenance = <MediaProvenance?>[];
    for (var i = 0; i < message.mediaRefs.length; i++) {
      final ref = message.mediaRefs[i];
      // A file goes as it is; a picture is re-encoded, at full size only
      // when the sender asked for it.
      final data = message.kind == 'file'
          ? (BlobRef.tryDecode(ref) != null
              ? ref
              : await MediaService.prepareFileForRelay(ref,
                  mimeType: message.payload?['mime'] as String? ?? 'application/octet-stream'))
          : await MediaService.prepareForRelay(ref,
              videoLimit: MediaService.chatVideoLimit,
              originalQuality: wantsOriginalQuality?.call() ?? false);
      if (data != null) {
        encoded.add(data);
        // Kept aligned with the refs: a dropped item takes its claim with it.
        provenance.add(MediaProvenance.at(message.provenance, i));
      }
    }
    return message.copyWith(mediaRefs: encoded, provenance: provenance, audioRef: audio);
  }

  /// Turn received media back into files on this device.
  Future<Message> _decodeMedia(Message message) async {
    String? audio = message.audioRef;
    if (audio != null && BlobRef.tryDecode(audio) != null) {
      // Kept as the reference when the fetch fails now; the player retries.
      audio = await MediaService.decodeAndSaveImage(audio) ?? audio;
    }
    if (message.mediaRefs.isEmpty) {
      return audio == message.audioRef ? message : message.copyWith(audioRef: audio);
    }

    final saved = <String>[];
    for (final ref in message.mediaRefs) {
      final path = message.kind == 'file'
          ? await MediaService.decodeAndSaveFile(ref,
              name: message.payload?['name'] as String? ?? 'file')
          : await MediaService.decodeAndSaveImage(ref);
      saved.add(path ?? ref);
    }
    return message.copyWith(mediaRefs: saved, audioRef: audio);
  }

  /// A nudge with no words. Once a minute per person at most, from this side.
  final Map<String, DateTime> _lastPoke = {};
  Future<Message> poke(String contactKey) async {
    final last = _lastPoke[contactKey];
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) {
      throw StateError('One poke a minute is plenty.');
    }
    _lastPoke[contactKey] = DateTime.now();
    return sendMessage(contactKey, '👉', kind: 'poke');
  }

  /// Whether pictures go at full size. Set by the app from the setting.
  bool Function()? wantsOriginalQuality;

  /// Send any file. It travels as an encrypted blob under its own name and
  /// type; the card on the other side opens it with whatever handles the type.
  Future<Message> sendFile(String contactKey,
          {required String path, required String name, required String mime, required int size}) =>
      sendMessage(contactKey, name,
          mediaRefs: [path], kind: 'file', payload: {'name': name, 'mime': mime, 'size': size});

  // ── Ignored chats ─────────────────────────────────────────────────────────

  /// An ignored chat's messages still arrive, but we tell its sender nothing:
  /// no typing, no read receipts, and no notification. Set by the app.
  bool Function(String peerKey)? isIgnored;

  // ── Scheduled messages ────────────────────────────────────────────────────

  static const _scheduledKey = 'spheres_scheduled_messages_v1';
  final List<ScheduledMessage> _scheduled = [];

  /// Messages waiting for their time, for one chat, soonest first.
  List<ScheduledMessage> scheduledFor(String peerKey) =>
      _scheduled.where((s) => s.peer == peerKey).toList()..sort((a, b) => a.at.compareTo(b.at));

  List<ScheduledMessage> get allScheduled => List.unmodifiable(_scheduled);

  /// Keep [content] to be sent to [peerKey] at [at]. Sent by this device,
  /// when it is running; the other side is told nothing until then.
  Future<ScheduledMessage> scheduleMessage(String peerKey, String content, DateTime at) async {
    if (content.trim().isEmpty) throw ArgumentError('Nothing to send');
    if (!at.isAfter(DateTime.now())) throw ArgumentError('That time has passed');
    final s = ScheduledMessage(
        id: const Uuid().v4(), peer: peerKey, content: content.trim(), at: at);
    _scheduled.add(s);
    await _persistScheduled();
    notifyListeners();
    return s;
  }

  Future<void> cancelScheduled(String id) async {
    _scheduled.removeWhere((s) => s.id == id);
    await _persistScheduled();
    notifyListeners();
  }

  /// Send everything whose time has come. Runs on the sweep timer and at
  /// start; returns how many went.
  Future<int> sendDueScheduled({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final due = _scheduled.where((s) => !s.at.isAfter(at)).toList();
    var sent = 0;
    for (final s in due) {
      try {
        await sendMessage(s.peer, s.content);
        _scheduled.remove(s);
        sent++;
      } catch (e) {
        DebugLogService().warn('Chat', 'A scheduled message could not go yet: $e');
      }
    }
    if (sent > 0) {
      await _persistScheduled();
      notifyListeners();
    }
    return sent;
  }

  Future<void> _persistScheduled() => SecureStore.instance
      .setString(_scheduledKey, jsonEncode([for (final s in _scheduled) s.toJson()]));

  Future<void> _loadScheduled() async {
    _scheduled.clear();
    final raw = await SecureStore.instance.getString(_scheduledKey);
    if (raw == null) return;
    try {
      for (final e in (jsonDecode(raw) as List).whereType<Map>()) {
        _scheduled.add(ScheduledMessage.fromJson(e.cast<String, dynamic>()));
      }
    } catch (_) {}
  }

  // ── Vanish mode ───────────────────────────────────────────────────────────
  //
  // A preset over disappearing messages: on means every message in the chat
  // disappears five minutes after it is sent, for both sides, and off puts
  // back whatever the chat had before. The other side sees it as the usual
  // "set messages to disappear" line; nothing here is hidden from them.

  static const vanishAfter = Duration(minutes: 5);
  static const _vanishKey = 'spheres_vanish_v1';
  final Map<String, int> _vanishBefore = {};

  bool isVanish(String peerKey) =>
      _vanishBefore.containsKey(peerKey) && disappearAfter(peerKey) == vanishAfter;

  Future<void> setVanish(String peerKey, bool on) async {
    if (on) {
      if (!_vanishBefore.containsKey(peerKey)) {
        _vanishBefore[peerKey] = disappearAfter(peerKey)?.inSeconds ?? 0;
      }
      await setDisappearing(peerKey, vanishAfter);
    } else {
      final before = _vanishBefore.remove(peerKey) ?? 0;
      await setDisappearing(peerKey, before == 0 ? null : Duration(seconds: before));
    }
    await SecureStore.instance.setString(_vanishKey, jsonEncode(_vanishBefore));
    notifyListeners();
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
      final plaintext = jsonEncode({
        'message_id': messageId,
        'emoji': emoji,
        'removed': removed,
        'peer': peerKey,
      });
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: peerKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(peerKey),
        type: 'chat_reaction',
        plaintext: plaintext,
      );
      await _relayService.sendSealed(peerKey, sealed);
      await sendToOwnDevices('chat_reaction', plaintext, mode: SealMode.chain);
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
  Future<void> _sendReceipt(String peerKey, String messageId,
      {String? toDevice}) async {
    final sessions = _sessions;
    if (sessions == null || !sessions.isReady) return;
    try {
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: peerKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(peerKey),
        type: 'receipt',
        plaintext: jsonEncode({'id': messageId}),
        // Only the device that sent it holds the outbox entry to clear.
        onlyDevice: toDevice,
      );
      await _relayService.sendSealed(peerKey, sealed);
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
        await _handleSessionReset(opened.from, opened.fromDevice, opened.plaintext);
        return;
      }

      // Anything that opens proves the chains agree again.
      _authFailures.remove('${opened.from}|${opened.fromDevice}');

      if (opened.type == 'profile') {
        final json = jsonDecode(opened.plaintext);
        if (json is Map<String, dynamic>) {
          if (opened.from == _myPublicKey) {
            // Edited on another of our devices: the same profile, here too.
            await onOwnProfile?.call(json);
          } else {
            await onProfile?.call(opened.from, json);
          }
        }
        return;
      }

      if (opened.type == 'devices') {
        final json = jsonDecode(opened.plaintext);
        if (json is Map) await onDeviceList?.call(opened.from, json['devices']);
        return;
      }

      final fromSelf = opened.from == _myPublicKey;
      if (opened.type == 'contacts') {
        DebugLogService().info('Chat',
            fromSelf ? 'Contact change from another of our devices' : 'Ignoring contacts envelope from a peer');
        if (fromSelf) {
          final json = jsonDecode(opened.plaintext);
          if (json is Map<String, dynamic>) await onContactSync?.call(json);
        }
        return;
      }

      if (opened.type == 'typing') {
        final stopped = jsonDecode(opened.plaintext)['stopped'] == true;
        if (_typing.noteSignal(opened.from, stopped: stopped)) {
          notifyListeners();
        }
        return;
      }

      if (_controlTypes.contains(opened.type)) {
        await _handleControl(opened, fromSelf);
        return;
      }

      if (opened.type == 'chat_reaction') {
        final payload = jsonDecode(opened.plaintext);
        final messageId = payload['message_id'];
        final emoji = payload['emoji'];
        if (messageId is String && emoji is String) {
          // Attributed to the verified sender, never to a field they set. A
          // copy from our own other device lands in the conversation it names.
          final conversation = fromSelf ? payload['peer'] : opened.from;
          if (conversation is String) {
            _applyReaction(conversation, messageId, opened.from, emoji);
          }
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

      if (fromSelf) {
        // Something we sent from another of our devices: file it under the
        // conversation it belongs to, and send no receipt to ourselves.
        _addMessageLocally(msg.recipientId, await _decodeMedia(msg));
        return;
      }
      _addMessageLocally(opened.from, await _decodeMedia(msg));
      await _sendReceipt(opened.from, msg.id, toDevice: opened.fromDevice);
    } on EnvelopeException catch (e) {
      DebugLogService().error('Chat', 'Rejected message from $contactKey: $e');
    } on UnknownDeviceException catch (e) {
      // They have a device we were not told about. Ask for their list, then
      // try this envelope again — once.
      final waiting = _awaitingDevice.putIfAbsent(e.peerKey, () => []);
      if (waiting.length < 20) waiting.add(raw);
      DebugLogService().info('Chat', 'Unknown device for ${e.peerKey}; refreshing');
      final refreshed = await onUnknownDevice?.call(e.peerKey) ?? false;
      final retry = _awaitingDevice.remove(e.peerKey) ?? const [];
      if (refreshed) {
        for (final pending in retry) {
          if (pending == raw) {
            await _handleRelayMessageOnce(contactKey, pending);
          } else {
            await _handleRelayMessage(contactKey, pending);
          }
        }
      }
    } on NoSessionException catch (e) {
      DebugLogService().warn('Chat', 'Cannot decrypt yet: $e');
    } on SecretBoxAuthenticationError catch (_) {
      // The signature verified — so this really is from them — but the payload
      // did not authenticate. That combination means only one thing: the two
      // sides no longer agree on where the chains are.
      DebugLogService()
          .warn('Chat', 'Could not authenticate a message from $contactKey');
      String peer = contactKey;
      String? device;
      try {
        final header = Envelope.decode(raw);
        peer = header.from;
        device = header.fromDevice.isEmpty ? null : header.fromDevice;
      } catch (_) {}
      if (peer == _myPublicKey) {
        // Our own message handed back by the shared mailbox. Nothing is
        // wrong with any session; there is simply nothing here for us.
        return;
      }
      await _noteAuthenticationFailure(peer, device);
    } catch (e) {
      DebugLogService().error('Chat', 'Failed to handle relay message: $e');
    }
  }

  static const _controlTypes = {
    'chat_edit', 'chat_delete', 'chat_pin', 'chat_settings', 'read',
    'poll_vote', 'location_update',
  };

  /// Apply a control message: an edit, an unsend, a pin, a timer, a read
  /// receipt, a vote, a location update. Everything is attributed to the
  /// signed sender; a copy from our own other device names the conversation.
  Future<void> _handleControl(OpenedEnvelope opened, bool fromSelf) async {
    final payload = jsonDecode(opened.plaintext);
    if (payload is! Map<String, dynamic>) return;
    final conversation = fromSelf ? payload['peer'] : opened.from;
    if (conversation is! String) return;
    final from = opened.from;

    switch (opened.type) {
      case 'chat_edit':
        final msg = _find(conversation, payload['message_id'] as String? ?? '');
        if (msg == null || msg.senderId != from) return;
        final at = DateTime.tryParse(payload['edited_at'] as String? ?? '') ?? DateTime.now();
        _replace(conversation, msg.copyWith(content: payload['content'] as String? ?? msg.content, editedAt: at));
      case 'chat_delete':
        final msg = _find(conversation, payload['message_id'] as String? ?? '');
        if (msg == null || msg.senderId != from) return;
        _replace(conversation, _tombstone(msg));
      case 'chat_pin':
        _applyPin(conversation, payload['message_id'] as String?);
      case 'chat_settings':
        final seconds = payload['disappear_seconds'];
        if (seconds is int && (_disappear[conversation] ?? 0) != seconds) {
          await _applyDisappearing(conversation, seconds, by: from);
        }
      case 'read':
        if (fromSelf) return;
        final ids = (payload['ids'] as List?)?.cast<String>() ?? const [];
        final list = _conversations[conversation];
        if (list == null) return;
        var changed = false;
        for (var i = 0; i < list.length; i++) {
          if (ids.contains(list[i].id) && !list[i].readBy.contains(from)) {
            list[i] = list[i].copyWith(readBy: [...list[i].readBy, from]);
            changed = true;
          }
        }
        if (changed) {
          await _persistMessages(conversation);
          notifyListeners();
        }
      case 'poll_vote':
        final msg = _find(conversation, payload['message_id'] as String? ?? '');
        if (msg == null || !msg.isPoll) return;
        final choices = (payload['choices'] as List?)?.whereType<int>().toList() ?? const [];
        _applyVote(conversation, msg, from, choices);
      case 'location_update':
        final msg = _find(conversation, payload['message_id'] as String? ?? '');
        if (msg == null || msg.senderId != from) return;
        _applyLocationUpdate(conversation, payload);
    }
  }

  /// Retry after a device-list refresh. If the device is still unknown the
  /// envelope is dropped, with a log line, rather than refreshing forever.
  Future<void> _handleRelayMessageOnce(String contactKey, String raw) async {
    final hook = onUnknownDevice;
    onUnknownDevice = (_) async => false;
    try {
      await _handleRelayMessage(contactKey, raw);
    } finally {
      onUnknownDevice = hook;
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

  Future<void> _noteAuthenticationFailure(String peerKey, String? deviceKey) async {
    // A session with ourselves does not exist and must never be "restarted":
    // doing so failed our own queued mail and announced to nobody.
    if (peerKey == _myPublicKey) return;
    final device = deviceKey ?? _resolveExchangeKey?.call(peerKey);
    final slot = '$peerKey|$device';
    final count = (_authFailures[slot] ?? 0) + 1;
    _authFailures[slot] = count;
    if (count < resetAfterFailures) return;

    final last = _lastReset[slot];
    if (last != null && DateTime.now().difference(last) < resetCooldown) {
      DebugLogService().warn('Chat',
          'Session with $peerKey still failing, but it was just restarted');
      return;
    }

    await _restartSession(peerKey, device, announce: true);
  }

  /// Restart a session because the user asked, not because we detected a fault.
  ///
  /// Bypasses the failure counter — they are telling us it is broken — but not
  /// the cooldown, so repeated taps cannot shred whatever is still in flight.
  Future<void> restartSessionManually(String peerKey) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final devices = sessions.devicesOf(peerKey,
        fallback: _resolveExchangeKey?.call(peerKey));
    for (final device in devices) {
      final last = _lastReset['$peerKey|$device'];
      if (last != null && DateTime.now().difference(last) < resetCooldown) {
        throw StateError(
          'This session was just re-established. Give it a minute before '
          'trying again.',
        );
      }
    }
    for (final device in devices) {
      await _restartSession(peerKey, device, announce: true);
    }
  }

  Future<void> _restartSession(String peerKey, String? deviceKey,
      {required bool announce}) async {
    final sessions = _sessions;
    if (sessions == null) return;

    try {
      final epoch = await sessions.beginReset(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: deviceKey ?? _resolveExchangeKey?.call(peerKey),
      );
      await _afterReset(peerKey, deviceKey, epoch);
      if (announce) await _announceReset(peerKey, deviceKey, epoch);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not restart the session: $e');
    }
  }

  /// Tell the peer device which epoch we have moved to.
  ///
  /// Wrapped rather than chained, because the chain is the broken thing — a
  /// request to fix it cannot depend on it working.
  Future<void> _announceReset(String peerKey, String? deviceKey, int epoch) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final sealed = await sessions.sealForDevices(
        peerIdentityKey: peerKey,
        fallbackExchangeKey: _resolveExchangeKey?.call(peerKey),
        type: 'session_reset',
        plaintext: jsonEncode({'epoch': epoch}),
        mode: SealMode.wrap,
        onlyDevice: deviceKey,
      );
      await _relayService.sendSealed(peerKey, sealed);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not announce the restart: $e');
    }
  }

  Future<void> _afterReset(String peerKey, String? deviceKey, int epoch) async {
    final slot = '$peerKey|${deviceKey ?? _resolveExchangeKey?.call(peerKey)}';
    _authFailures.remove(slot);
    _lastReset[slot] = DateTime.now();
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

  Future<void> _handleSessionReset(
      String peerKey, String deviceKey, String payload) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final epoch = jsonDecode(payload)['epoch'];
      if (epoch is! int || epoch < 1) return;

      final changed = await sessions.adoptReset(
        peerIdentityKey: peerKey,
        peerKeyExchangePublicKey: deviceKey,
        epoch: epoch,
      );
      if (!changed) return;

      await _afterReset(peerKey, deviceKey, epoch);
      // Echo it back so a peer that has not caught up converges too. Adopting
      // is idempotent, so this cannot bounce.
      await _announceReset(peerKey, deviceKey, epoch);
    } catch (e) {
      DebugLogService().error('Chat', 'Could not apply a session restart: $e');
    }
  }

  /// Display name for an identity key, supplied by the app so this service
  /// need not know about contacts. Used for notifications only.
  String Function(String identityKey)? resolveName;

  void _addMessageLocally(String contactKey, Message msg, {bool notify = true}) {
    // Arrived after its own deadline: it was never meant to be seen now.
    if (msg.isExpired) return;
    // Seen as it arrives when the chat is on screen.
    if (contactKey == _activeConversation) _stampOpened(contactKey);
    _conversations.putIfAbsent(contactKey, () => []);
    if (!_conversations[contactKey]!.any((m) => m.id == msg.id)) {
      _conversations[contactKey]!.add(msg);
      _conversations[contactKey]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _persistMessages(contactKey);
      notifyListeners();
      if (notify && msg.senderId != _myPublicKey && !msg.isSystem) {
        if (_activeConversation == contactKey) unawaited(markRead(contactKey));
        InboundEvents.emit(InboundEvent(
          kind: InboundKind.chat,
          id: 'chat:${msg.id}',
          title: resolveName?.call(msg.senderId) ?? 'New message',
          body: describeMessage(msg),
          route: '/chat/$contactKey',
          thread: 'chat:$contactKey',
          from: msg.senderId,
        ));
      }
    }
  }

  /// One line for a notification or a list row.
  static String describeMessage(Message msg) {
    if (msg.isDeleted) return 'Message deleted';
    if (msg.kind == 'file') return 'File: ${msg.payload?['name'] ?? msg.content}';
    if (msg.kind == 'poke') return 'Poked you 👉';
    if (msg.isPoll) return 'Poll: ${msg.payload?['question'] ?? msg.content}';
    if (msg.isLocation) return 'Shared a location';
    if (msg.isContactCard) return 'Shared a contact';
    if (msg.viewOnce) return 'Photo or video, view once';
    if (msg.audioRef != null) return 'Voice note';
    if (msg.mediaRefs.isNotEmpty) {
      final video = msg.mediaRefs.any(MediaService.looksLikeVideo) ||
          msg.content == '[Video]';
      final label = video ? 'Video' : 'Photo';
      final text = msg.content.trim();
      if (text.isEmpty || text == '[Image]' || text == '[Video]') return label;
      return '$label · $text';
    }
    return msg.content;
  }

  @override
  void dispose() {
    _typingSweep?.cancel();
    _expirySweep?.cancel();
    for (final t in _liveLocation.values) {
      t.cancel();
    }
    super.dispose();
  }

  Future<void> loadConversations() async {
    final store = SecureStore.instance;
    _sendReadReceipts = await store.getBool(_readReceiptsKey) ?? true;
    await _loadScheduled();
    try {
      final vanish = await store.getString(_vanishKey);
      if (vanish != null) {
        (jsonDecode(vanish) as Map).forEach((k, v) {
          if (v is int) _vanishBefore[k.toString()] = v;
        });
      }
    } catch (_) {}
    try {
      final raw = await store.getString(_settingsKey);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          if (v is int) _disappear[k] = v;
        });
      }
      final pins = await store.getString(_pinsKey);
      if (pins != null) {
        (jsonDecode(pins) as Map<String, dynamic>).forEach((k, v) {
          if (v is String) _pins[k] = v;
        });
      }
      final opened = await store.getString(_lastOpenedKey);
      if (opened != null) {
        (jsonDecode(opened) as Map<String, dynamic>).forEach((k, v) {
          final d = v is String ? DateTime.tryParse(v) : null;
          if (d != null) _lastOpened[k] = d;
        });
      }
    } catch (_) {}
    _startExpirySweep();
    await _loadConversationsFromStore();
    await sweepExpired();
  }

  Future<void> _loadConversationsFromStore() async {
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

/// A message kept on this device until its time, then sent as any other.
class ScheduledMessage {
  final String id;
  final String peer;
  final String content;
  final DateTime at;
  const ScheduledMessage({required this.id, required this.peer, required this.content, required this.at});

  Map<String, dynamic> toJson() => {'id': id, 'peer': peer, 'content': content, 'at': at.toIso8601String()};

  factory ScheduledMessage.fromJson(Map<String, dynamic> j) => ScheduledMessage(
        id: j['id'] as String,
        peer: j['peer'] as String,
        content: j['content'] as String,
        at: DateTime.parse(j['at'] as String),
      );
}
