import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../models/sphere.dart';
import 'debug_log_service.dart';
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

  /// Sends one already-sealed payload to one member. Supplied by the app.
  Future<bool> Function(String peerIdentityKey, String payload)? sendToPeer;

  /// Members we will not send to. Blocking is one-sided and local.
  Set<String> Function()? blockedKeys;

  /// The sphere whose thread is on screen, so its messages are not counted as
  /// unread while the user is looking at them.
  String? _openThread;

  void configure({required String identityKey}) {
    _myIdentityKey = identityKey;
  }

  List<Message> messagesIn(String sphereId) =>
      List.unmodifiable(_threads[sphereId] ?? const <Message>[]);

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
    if (sphereId != null) _unread.remove(sphereId);
  }

  final Map<String, int> _unread = {};

  int unreadIn(String sphereId) => _unread[sphereId] ?? 0;

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
  }) async {
    final me = _myIdentityKey;
    if (me == null) throw StateError('No identity yet');

    final sphere = _spheres.sphere(sphereId);
    if (sphere == null) throw StateError('You are not in this sphere');
    if (sphere.kind == SphereKind.broadcast && !sphere.isAdmin(me)) {
      throw StateError('Only admins post in this sphere');
    }

    final message = Message(
      id: _uuid.v4(),
      senderId: me,
      recipientId: sphereId,
      content: content,
      timestamp: DateTime.now(),
      replyToMessageId: replyToMessageId,
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

    await _fanOut(sphere, sealed);
    return message;
  }

  Future<void> _fanOut(Sphere sphere, String sealed) async {
    final send = sendToPeer;
    if (send == null) return;
    final blocked = blockedKeys?.call() ?? const <String>{};

    for (final member in sphere.members.map((m) => m.identityKey)) {
      if (member == _myIdentityKey || blocked.contains(member)) continue;
      try {
        await send(member, sealed);
      } catch (e) {
        DebugLogService()
            .warn('SphereChat', 'Could not reach a member of "${sphere.name}": $e');
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
    try {
      final message = Message.fromJson(payload['message'] as Map<String, dynamic>);

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
      }
      await _persist(sphereId);
      notifyListeners();
    } catch (e) {
      DebugLogService().error('SphereChat', 'Could not apply a message: $e');
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
