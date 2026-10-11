import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../crypto/blob.dart';
import '../models/media_provenance.dart';
import '../models/message.dart';
import '../models/sphere.dart';
import 'chat_service.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'inbound_events.dart';
import 'secure_store.dart';
import 'sphere_service.dart';

/// Conversations that belong to a sphere rather than to one other person.
///
/// A sphere message is addressed to the sphere, so [Message.recipientId] holds
/// the sphere id. That is not a shortcut: in this app a direct message is
/// already a sphere of two, and treating the sphere as the recipient is what
/// lets group threads reuse the same message model, the same bubble widget,
/// and the same replies and reactions as a one-to-one chat.
///
/// Delivery differs from a direct message in one important way. There is no
/// ratcheted chain, because a chain only works between two people who advance
/// it in lockstep. Content is sealed once with the sphere's epoch key and the
/// same sealed bytes are sent to every member, exactly as feed posts are. The
/// consequence is honest and worth stating: **group messages do not have
/// forward secrecy.** Someone who later obtains a sphere key can read every
/// message sent during that epoch. Membership changes rotate the key, so the
/// window is bounded by the epoch rather than by the message.
class SphereChatService extends ChangeNotifier {
  static const _prefsPrefix = 'spheres_sphere_msgs_';
  static const _prefsIndexKey = 'spheres_sphere_chats_v1';

  /// Kept per sphere so a busy sphere cannot crowd out a quiet one.
  static const int maxMessagesPerSphere = 500;

  final SphereService _spheres;
  final _uuid = const Uuid();

  SphereChatService(this._spheres);

  /// Messages by sphere id, oldest first.
  final Map<String, List<Message>> _threads = {};

  /// Ids of spheres we have ever stored messages for, so load knows where to
  /// look without scanning every key.
  final Set<String> _known = {};

  String? _myIdentityKey;

  /// Hands one member's copy to a durable queue. Supplied by the app.
  ///
  /// A queue rather than a bare send: the relay only stores a message it
  /// actually receives, so if our socket is down at the moment of sending
  /// there is nothing anywhere and the message is gone. That is the whole
  /// reason a message written while someone was offline never arrived.
  Future<void> Function({
    required String id,
    required String member,
    required String sealed,
  })? queueForMember;

  /// Members we will not send to. Blocking is one-sided and local.
  Set<String> Function()? blockedKeys;

  /// The sphere whose thread is on screen, so its messages are not counted as
  /// unread while the user is looking at them.
  String? _openThread;

  /// Display name for an identity key, for notifications. Set by the app.
  String Function(String identityKey)? resolveName;

  void configure({required String identityKey}) {
    _myIdentityKey = identityKey;
  }

  /// Members muted within a sphere, by sphere id. Set by the app.
  Set<String> Function(String sphereId)? mutedMembers;

  /// The user's hidden-words filter. Set by the app.
  bool Function(String text)? hidesText;

  List<Message> messagesIn(String sphereId) {
    final thread = _threads[sphereId] ?? const <Message>[];
    final muted = mutedMembers?.call(sphereId) ?? const <String>{};
    final filter = hidesText;
    if (muted.isEmpty && filter == null) return List.unmodifiable(thread);
    return List.unmodifiable(thread.where((m) =>
        !muted.contains(m.senderId) &&
        (m.senderId == _myIdentityKey || !(filter?.call(m.content) ?? false))));
  }

  /// Spheres with at least one message, most recently active first.
  List<String> get activeThreads {
    final ids = _threads.keys.where((id) => _threads[id]!.isNotEmpty).toList();
    ids.sort((a, b) =>
        _threads[b]!.last.timestamp.compareTo(_threads[a]!.last.timestamp));
    return ids;
  }

  Message? lastMessageIn(String sphereId) {
    final thread = _threads[sphereId];
    if (thread == null || thread.isEmpty) return null;
    return thread.last;
  }

  void setOpenThread(String? sphereId) {
    _openThread = sphereId;
    if (sphereId != null && _unread.remove(sphereId) != null) _persistUnread();
  }

  /// Unread per sphere, kept on disk so a restart does not forget what was
  /// never opened.
  static const _unreadKey = 'spheres_sphere_chat_unread_v1';
  final Map<String, int> _unread = {};

  int unreadIn(String sphereId) => _unread[sphereId] ?? 0;

  Future<void> _persistUnread() =>
      SecureStore.instance.setString(_unreadKey, jsonEncode(_unread));

  // ── Sending ────────────────────────────────────────────────────────────────

  /// Post a message to a sphere.
  ///
  /// Throws if we cannot seal for the sphere — usually because we are waiting
  /// for an admin to send the current epoch key. Failing loudly is deliberate:
  /// a message that silently goes nowhere is worse than one that visibly did
  /// not send.
  Future<Message> sendMessage(
    String sphereId,
    String content, {
    String? replyToMessageId,
    List<String> mentions = const [],
    String kind = 'text',
    Map<String, dynamic>? payload,
    bool forwarded = false,
    List<String> mediaRefs = const [],
    List<MediaProvenance?>? provenance,
  }) async {
    final me = _myIdentityKey;
    if (me == null) throw StateError('No identity yet');

    final sphere = _spheres.sphere(sphereId);
    if (sphere == null) throw StateError('You are not in this sphere');
    if (sphere.kind == SphereKind.broadcast && !sphere.isAdmin(me)) {
      throw StateError('Only admins post in this sphere');
    }

    // Local files become encrypted blobs before the message exists, so a
    // forwarded photo reaches the sphere as media and not as a path into the
    // sender's sandbox. A reference that is already a blob passes through.
    final claims = provenance ?? MediaService.provenanceListFor(mediaRefs);
    final encodedRefs = <String>[];
    final encodedClaims = <MediaProvenance?>[];
    for (var i = 0; i < mediaRefs.length; i++) {
      final ref = mediaRefs[i];
      final data = BlobRef.tryDecode(ref) != null
          ? ref
          : await MediaService.prepareForRelay(ref,
              videoLimit: MediaService.chatVideoLimit);
      if (data == null) continue;
      encodedRefs.add(data);
      encodedClaims.add(MediaProvenance.at(claims, i));
    }

    final ttl = disappearAfter(sphereId);
    final message = Message(
      id: _uuid.v4(),
      senderId: me,
      recipientId: sphereId,
      content: content,
      timestamp: DateTime.now(),
      replyToMessageId: replyToMessageId,
      mentions: mentions.where(sphere.contains).toList(),
      kind: kind,
      payload: payload,
      forwarded: forwarded,
      mediaRefs: encodedRefs,
      provenance: encodedClaims,
      expiresAt: ttl == null ? null : DateTime.now().add(ttl),
    );

    // Sealed before it is shown, so a sphere we cannot encrypt for never looks
    // as though the message went out.
    final sealed = await _spheres.sealContent(
      sphereId: sphereId,
      type: 'sphere_content',
      plaintext: jsonEncode({'type': 'sphere_msg', 'message': message.toJson()}),
    );

    _append(sphereId, message);
    await _persist(sphereId);
    notifyListeners();

    await _fanOut(sphere, sealed, message.id);
    return message;
  }

  // ── Edits, unsends, pins, timers, votes, reads ────────────────────────────

  static const _settingsKey = 'spheres_sphere_chat_settings_v1';
  static const _pinsKey = 'spheres_sphere_chat_pins_v1';
  static const Duration editWindow = Duration(minutes: 15);

  final Map<String, int> _disappear = {};
  final Map<String, String> _pins = {};
  final Set<String> _readSent = {};

  /// Read receipts in a group fan out to every member; reuses the direct-chat
  /// preference so there is one switch for "do I say what I have read".
  bool Function()? sendReadReceipts;

  Duration? disappearAfter(String sphereId) {
    final seconds = _disappear[sphereId];
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  String? pinnedMessageId(String sphereId) => _pins[sphereId];

  Message? _find(String sphereId, String messageId) {
    for (final m in _threads[sphereId] ?? const <Message>[]) {
      if (m.id == messageId) return m;
    }
    return null;
  }

  Future<void> _replace(String sphereId, Message updated) async {
    final list = _threads[sphereId];
    if (list == null) return;
    final index = list.indexWhere((m) => m.id == updated.id);
    if (index == -1) return;
    list[index] = updated;
    await _persist(sphereId);
    notifyListeners();
  }

  /// Seal and fan out a control payload about this sphere's conversation.
  Future<void> _control(String sphereId, String type, Map<String, dynamic> body) async {
    final sphere = _spheres.sphere(sphereId);
    if (sphere == null) return;
    final sealed = await _spheres.sealContent(
      sphereId: sphereId,
      type: 'sphere_content',
      plaintext: jsonEncode({'type': type, ...body}),
    );
    await _fanOut(sphere, sealed, '$type:${_uuid.v4()}');
  }

  Future<void> editMessage(String sphereId, String messageId, String text) async {
    final msg = _find(sphereId, messageId);
    if (msg == null || msg.senderId != _myIdentityKey) {
      throw StateError('Only your own messages can be edited');
    }
    if (DateTime.now().difference(msg.timestamp) > editWindow) {
      throw StateError('Messages can be edited for ${editWindow.inMinutes} minutes after sending');
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == msg.content) return;
    final at = DateTime.now();
    await _replace(sphereId, msg.copyWith(content: trimmed, editedAt: at));
    await _control(sphereId, 'sphere_msg_edit',
        {'message_id': messageId, 'content': trimmed, 'edited_at': at.toIso8601String()});
  }

  Future<void> deleteForEveryone(String sphereId, String messageId) async {
    final msg = _find(sphereId, messageId);
    final me = _myIdentityKey;
    final sphere = _spheres.sphere(sphereId);
    if (msg == null || me == null || sphere == null) return;
    // Authors unsend their own; admins may remove anything, as moderation.
    if (msg.senderId != me && !sphere.isAdmin(me)) {
      throw StateError('Only the author or an admin can remove this');
    }
    await _replace(sphereId, _tombstone(msg));
    await _control(sphereId, 'sphere_msg_delete', {'message_id': messageId});
  }

  Message _tombstone(Message m) => Message(
        id: m.id,
        senderId: m.senderId,
        recipientId: m.recipientId,
        content: '',
        timestamp: m.timestamp,
        deletedAt: DateTime.now(),
        replyToMessageId: m.replyToMessageId,
        readBy: m.readBy,
      );

  Future<void> pinMessage(String sphereId, String? messageId) async {
    final me = _myIdentityKey;
    final sphere = _spheres.sphere(sphereId);
    if (me == null || sphere == null) return;
    if (!sphere.isAdmin(me)) throw StateError('Only an admin can pin here');
    await _applyPin(sphereId, messageId);
    await _control(sphereId, 'sphere_msg_pin', {'message_id': messageId});
  }

  Future<void> _applyPin(String sphereId, String? messageId) async {
    if (messageId == null) {
      _pins.remove(sphereId);
    } else {
      _pins[sphereId] = messageId;
    }
    await SecureStore.instance.setString(_pinsKey, jsonEncode(_pins));
    notifyListeners();
  }

  Future<void> setDisappearing(String sphereId, Duration? after) async {
    final me = _myIdentityKey;
    final sphere = _spheres.sphere(sphereId);
    if (me == null || sphere == null) return;
    if (!sphere.isAdmin(me)) throw StateError('Only an admin can change the timer');
    final seconds = after?.inSeconds ?? 0;
    await _applyDisappearing(sphereId, seconds, by: me);
    await _control(sphereId, 'sphere_msg_settings', {'disappear_seconds': seconds});
  }

  Future<void> _applyDisappearing(String sphereId, int seconds, {required String by}) async {
    if ((_disappear[sphereId] ?? 0) == seconds) return;
    if (seconds <= 0) {
      _disappear.remove(sphereId);
    } else {
      _disappear[sphereId] = seconds;
    }
    await SecureStore.instance.setString(_settingsKey, jsonEncode(_disappear));
    final who = by == _myIdentityKey ? 'You' : (resolveName?.call(by) ?? 'An admin');
    _append(sphereId, Message(
      id: _uuid.v4(),
      senderId: by,
      recipientId: sphereId,
      content: seconds <= 0
          ? '$who turned off disappearing messages.'
          : '$who set messages to disappear after ${ChatService.describeDuration(Duration(seconds: seconds))}.',
      timestamp: DateTime.now(),
      kind: 'system',
    ));
    await _persist(sphereId);
    notifyListeners();
  }

  Future<Message> sendPoll(String sphereId, String question, List<String> options,
          {bool multiple = false, bool anonymous = false}) =>
      sendMessage(sphereId, question, kind: 'poll', payload: {
        'question': question,
        'options': options,
        'multiple': multiple,
        'anonymous': anonymous,
        'votes': <String, dynamic>{},
      });

  Future<void> votePoll(String sphereId, String messageId, List<int> choices) async {
    final msg = _find(sphereId, messageId);
    final me = _myIdentityKey;
    if (msg == null || me == null || !msg.isPoll) return;
    await _applyVote(sphereId, msg, me, choices);
    await _control(sphereId, 'sphere_msg_vote', {'message_id': messageId, 'choices': choices});
  }

  Future<void> _applyVote(String sphereId, Message poll, String voter, List<int> choices) async {
    final payload = Map<String, dynamic>.from(poll.payload ?? {});
    final count = (payload['options'] as List?)?.length ?? 0;
    var valid = choices.where((c) => c >= 0 && c < count).toSet().toList()..sort();
    if (payload['multiple'] != true && valid.length > 1) valid = [valid.first];
    final votes = Map<String, dynamic>.from(payload['votes'] as Map? ?? {});
    final key = payload['anonymous'] == true ? ChatService.voterHash(voter, poll.id) : voter;
    if (valid.isEmpty) {
      votes.remove(key);
    } else {
      votes[key] = valid;
    }
    payload['votes'] = votes;
    await _replace(sphereId, poll.copyWith(payload: payload));
  }

  /// The thread is on screen: tell the sphere what we have read.
  Future<void> markRead(String sphereId) async {
    if (!(sendReadReceipts?.call() ?? true)) return;
    final unread = (_threads[sphereId] ?? const <Message>[])
        .where((m) => m.senderId != _myIdentityKey && !m.isSystem && !_readSent.contains(m.id))
        .map((m) => m.id)
        .toList();
    if (unread.isEmpty) return;
    _readSent.addAll(unread);
    try {
      await _control(sphereId, 'sphere_msg_read', {'ids': unread});
    } catch (_) {}
  }

  /// Drop messages whose time is up.
  Future<void> sweepExpired() async {
    for (final entry in _threads.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((m) => m.isExpired);
      if (entry.value.length != before) await _persist(entry.key);
    }
    notifyListeners();
  }

  Future<void> _fanOut(Sphere sphere, String sealed, String messageId) async {
    final queue = queueForMember;
    if (queue == null) {
      DebugLogService()
          .error('SphereChat', 'No transport attached; the message stays here');
      return;
    }
    final blocked = blockedKeys?.call() ?? const <String>{};

    for (final member in sphere.members.map((m) => m.identityKey)) {
      if (member == _myIdentityKey || blocked.contains(member)) continue;
      try {
        // One queue entry per recipient, because each is delivered separately.
        await queue(id: '$messageId:$member', member: member, sealed: sealed);
      } catch (e) {
        DebugLogService().error(
            'SphereChat', 'Could not queue for a member of "${sphere.name}": $e');
      }
    }
  }

  // ── Receiving ──────────────────────────────────────────────────────────────

  /// Apply a sphere message that has already been verified and decrypted.
  ///
  /// [authorId] comes from the envelope signature and [sphereId] from the
  /// envelope header, both of which the sphere layer has already checked
  /// against the member list. The payload's own claims are not trusted where
  /// they disagree.
  Future<void> handleIncoming(
    String authorId,
    String sphereId,
    Map<String, dynamic> payload,
  ) async {
    final type = payload['type'];
    if (type != 'sphere_msg') {
      await _handleControl(authorId, sphereId, type as String? ?? '', payload);
      return;
    }
    try {
      final message = Message.fromJson(payload['message'] as Map<String, dynamic>);
      if (message.isExpired) return;

      if (message.senderId != authorId || message.recipientId != sphereId) {
        DebugLogService().warn('SphereChat',
            'Dropping a message whose payload disagrees with its envelope');
        return;
      }
      final sphere = _spheres.sphere(sphereId);
      if (sphere == null) return;
      if (sphere.kind == SphereKind.broadcast && !sphere.isAdmin(authorId)) {
        DebugLogService().warn(
            'SphereChat', 'Dropping a message from a non-admin in a broadcast');
        return;
      }

      final thread = _threads[sphereId];
      if (thread != null && thread.any((m) => m.id == message.id)) return;

      _append(sphereId, message);
      if (_openThread != sphereId) {
        _unread[sphereId] = (_unread[sphereId] ?? 0) + 1;
        await _persistUnread();
      }
      await _persist(sphereId);
      notifyListeners();
      if (authorId != _myIdentityKey) {
        final who = resolveName?.call(authorId) ?? 'Someone';
        final mentioned = message.mentions.contains(_myIdentityKey);
        InboundEvents.emit(InboundEvent(
          kind: InboundKind.sphereChat,
          id: 'sphere-msg:${message.id}',
          title: mentioned ? '${sphere.name} · mentioned you' : sphere.name,
          body: '$who: ${ChatService.describeMessage(message)}',
          route: '/sphere/$sphereId/chat',
          thread: 'sphere:$sphereId',
        ));
      }
    } catch (e) {
      DebugLogService().error('SphereChat', 'Could not apply a message: $e');
    }
  }

  Future<void> _handleControl(
      String from, String sphereId, String type, Map<String, dynamic> payload) async {
    final sphere = _spheres.sphere(sphereId);
    if (sphere == null) return;
    try {
      switch (type) {
        case 'sphere_msg_edit':
          final msg = _find(sphereId, payload['message_id'] as String? ?? '');
          if (msg == null || msg.senderId != from) return;
          final at = DateTime.tryParse(payload['edited_at'] as String? ?? '') ?? DateTime.now();
          await _replace(sphereId, msg.copyWith(content: payload['content'] as String? ?? msg.content, editedAt: at));
        case 'sphere_msg_delete':
          final msg = _find(sphereId, payload['message_id'] as String? ?? '');
          if (msg == null) return;
          if (msg.senderId != from && !sphere.isAdmin(from)) return;
          await _replace(sphereId, _tombstone(msg));
        case 'sphere_msg_pin':
          if (!sphere.isAdmin(from)) return;
          await _applyPin(sphereId, payload['message_id'] as String?);
        case 'sphere_msg_settings':
          if (!sphere.isAdmin(from)) return;
          final seconds = payload['disappear_seconds'];
          if (seconds is int) await _applyDisappearing(sphereId, seconds, by: from);
        case 'sphere_msg_vote':
          final msg = _find(sphereId, payload['message_id'] as String? ?? '');
          if (msg == null || !msg.isPoll) return;
          final choices = (payload['choices'] as List?)?.whereType<int>().toList() ?? const [];
          await _applyVote(sphereId, msg, from, choices);
        case 'sphere_msg_read':
          final ids = (payload['ids'] as List?)?.cast<String>() ?? const [];
          final list = _threads[sphereId];
          if (list == null) return;
          var changed = false;
          for (var i = 0; i < list.length; i++) {
            if (ids.contains(list[i].id) && !list[i].readBy.contains(from)) {
              list[i] = list[i].copyWith(readBy: [...list[i].readBy, from]);
              changed = true;
            }
          }
          if (changed) {
            await _persist(sphereId);
            notifyListeners();
          }
        default:
          DebugLogService().warn('SphereChat', 'Unknown control $type');
      }
    } catch (e) {
      DebugLogService().error('SphereChat', 'Could not apply $type: $e');
    }
  }

  void _append(String sphereId, Message message) {
    final thread = _threads.putIfAbsent(sphereId, () => []);
    thread.add(message);
    // Out-of-order arrival is normal: the relay does not promise ordering.
    thread.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (thread.length > maxMessagesPerSphere) {
      thread.removeRange(0, thread.length - maxMessagesPerSphere);
    }
    _known.add(sphereId);
  }

  /// Drop a sphere's thread when we leave it or are removed.
  Future<void> forget(String sphereId) async {
    _threads.remove(sphereId);
    _unread.remove(sphereId);
    _known.remove(sphereId);
    await SecureStore.instance.remove('$_prefsPrefix$sphereId');
    await SecureStore.instance.setStringList(_prefsIndexKey, _known.toList());
    notifyListeners();
  }

  /// Forget threads for spheres we are no longer in.
  ///
  /// Leaving discards the keys, so the messages would be unreadable anyway;
  /// this stops them lingering on disk.
  Future<void> pruneDepartedSpheres() async {
    final live = _spheres.spheres.map((s) => s.id).toSet();
    for (final id in _known.toList()) {
      if (!live.contains(id)) await forget(id);
    }
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final store = SecureStore.instance;
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
      final unread = await store.getString(_unreadKey);
      if (unread != null) {
        (jsonDecode(unread) as Map<String, dynamic>).forEach((k, v) {
          if (v is int && v > 0) _unread[k] = v;
        });
      }
    } catch (_) {}
    final store = SecureStore.instance;
    _known.addAll(await store.getStringList(_prefsIndexKey) ?? const []);

    for (final sphereId in _known.toList()) {
      final raw = await store.getString('$_prefsPrefix$sphereId');
      if (raw == null) continue;
      try {
        _threads[sphereId] = (jsonDecode(raw) as List<dynamic>)
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList();
      } catch (e) {
        DebugLogService()
            .error('SphereChat', 'Could not read messages for $sphereId: $e');
      }
    }
    notifyListeners();
  }

  Future<void> _persist(String sphereId) async {
    final thread = _threads[sphereId] ?? const <Message>[];
    await SecureStore.instance.setString(
      '$_prefsPrefix$sphereId',
      jsonEncode(thread.map((m) => m.toJson()).toList()),
    );
    await SecureStore.instance.setStringList(_prefsIndexKey, _known.toList());
  }
}
