import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';
import '../models/message.dart';
import 'crypto_service.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Manages groups with decentralized, encrypted group messaging and management.
class GroupService extends ChangeNotifier {
  static const _groupsKey = 'spheres_groups';
  static const _msgPrefix = 'spheres_group_msgs_';

  List<Group> _groups = [];
  final Map<String, List<Message>> _groupMessages = {};
  final RelayService _groupRelay = RelayService();
  String? _myPublicKey;
  String? _mySecretKey;

  List<Group> get groups => List.unmodifiable(_groups);
  Map<String, List<Message>> get groupMessages => Map.unmodifiable(_groupMessages);

  void initSync(String myPublicKey, String mySecretKey) {
    _myPublicKey = myPublicKey;
    _mySecretKey = mySecretKey;
    _groupRelay.onMessageReceived = (groupKey, data) {
      _handleGroupMessage(groupKey, data);
    };

    for (final group in _groups) {
      _groupRelay.connect('grp:${group.dhtKey}', 'grp:${group.dhtKey}', mySecretKey: _mySecretKey!);
    }
  }

  Future<void> loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final groupsJson = prefs.getString(_groupsKey);
    if (groupsJson != null) {
      try {
        final list = jsonDecode(groupsJson) as List<dynamic>;
        _groups = list.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
      } catch (e) {
        debugPrint('[GroupService] Failed to load groups: $e');
        _groups = [];
      }
    }

    for (final group in _groups) {
      final msgsJson = prefs.getString('$_msgPrefix${group.dhtKey}');
      if (msgsJson != null) {
        try {
          final list = jsonDecode(msgsJson) as List<dynamic>;
          _groupMessages[group.dhtKey] =
              list.map((e) => Message.fromJson(e as Map<String, dynamic>)).toList();
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  Future<void> createGroup(
    String name,
    String description, {
    required String publicKey,
    required String displayName,
  }) async {
    final dhtKey = const Uuid().v4();
    final now = DateTime.now();

    final creator = GroupMember(
      publicKey: publicKey,
      displayName: displayName,
      role: GroupRole.admin,
      joinedAt: now,
    );

    final group = Group(
      dhtKey: dhtKey,
      name: name,
      description: description,
      createdBy: publicKey,
      createdAt: now,
      members: [creator],
    );

    _groups.add(group);
    await _persist();
    notifyListeners();

    _groupRelay.connect('grp:$dhtKey', 'grp:$dhtKey', mySecretKey: _mySecretKey!);
  }

  Future<void> updateGroup(String dhtKey, {String? name, String? description}) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;
    _groups[index] = _groups[index].copyWith(
      name: name ?? _groups[index].name,
      description: description ?? _groups[index].description,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> addMember(String dhtKey, String publicKey, String displayName,
      {GroupRole role = GroupRole.member}) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;
    final group = _groups[index];
    if (group.members.any((m) => m.publicKey == publicKey)) return;

    final member = GroupMember(
      publicKey: publicKey,
      displayName: displayName,
      role: role,
      joinedAt: DateTime.now(),
    );

    _groups[index] = group.copyWith(members: [...group.members, member]);
    await _persist();
    notifyListeners();
  }

  Future<void> removeMember(String dhtKey, String publicKey) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;
    final group = _groups[index];
    _groups[index] = group.copyWith(
      members: group.members.where((m) => m.publicKey != publicKey).toList(),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> promoteMember(String dhtKey, String publicKey) async {
    _setRole(dhtKey, publicKey, GroupRole.admin);
  }

  Future<void> demoteMember(String dhtKey, String publicKey) async {
    _setRole(dhtKey, publicKey, GroupRole.member);
  }

  Future<void> _setRole(String dhtKey, String publicKey, GroupRole role) async {
    final gi = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (gi == -1) return;
    final members = List<GroupMember>.from(_groups[gi].members);
    final mi = members.indexWhere((m) => m.publicKey == publicKey);
    if (mi != -1) {
      members[mi] = members[mi].copyWith(role: role);
      _groups[gi] = _groups[gi].copyWith(members: members);
      await _persist();
      notifyListeners();
    }
  }

  Future<void> leaveGroup(String dhtKey, String publicKey) async {
    await removeMember(dhtKey, publicKey);
    if (getGroup(dhtKey)?.members.isEmpty ?? false) {
      await deleteGroup(dhtKey);
    }
  }

  Future<void> sendGroupMessage(String dhtKey, String senderId, String content) async {
    final groupKey = CryptoService.deriveSharedKey(dhtKey, _myPublicKey ?? senderId);
    final encryptedPayload = CryptoService.encrypt(content, groupKey);

    final message = Message(
      id: const Uuid().v4(),
      senderId: senderId,
      recipientId: dhtKey,
      content: content,
      timestamp: DateTime.now(),
      delivered: true,
    );

    _groupMessages.putIfAbsent(dhtKey, () => []);
    _groupMessages[dhtKey]!.add(message);
    notifyListeners();

    final payload = jsonEncode({
      'type': 'group_msg',
      'group_id': dhtKey,
      'encrypted_message': encryptedPayload,
      'sender_id': senderId,
      'id': message.id,
      'timestamp': message.timestamp.toIso8601String(),
    });
    
    _groupRelay.sendViaRelay('grp:$dhtKey', payload);
    await _persistMessages(dhtKey);
  }

  void _handleGroupMessage(String groupKey, String data) {
    try {
      final payload = jsonDecode(data) as Map<String, dynamic>;
      if (payload['type'] != 'group_msg') return;

      final groupId = payload['group_id'] as String;
      final encryptedMsg = payload['encrypted_message'] as String;
      final senderId = payload['sender_id'] as String;

      if (senderId == _myPublicKey || senderId == 'self') return;

      final groupKey = CryptoService.deriveSharedKey(groupId, _myPublicKey ?? senderId);
      final decryptedContent = CryptoService.decrypt(encryptedMsg, groupKey);

      final message = Message(
        id: payload['id'],
        senderId: senderId,
        recipientId: groupId,
        content: decryptedContent,
        timestamp: DateTime.parse(payload['timestamp']),
      );

      if (_groupMessages[groupId]?.any((m) => m.id == message.id) ?? false) return;

      _groupMessages.putIfAbsent(groupId, () => []);
      _groupMessages[groupId]!.add(message);
      notifyListeners();
      _persistMessages(groupId);
    } catch (e) {
      DebugLogService().error('Group', 'Failed to handle group message: $e');
    }
  }

  List<Message> getGroupMessages(String dhtKey) => _groupMessages[dhtKey] ?? [];

  Future<void> deleteGroup(String dhtKey) async {
    _groups.removeWhere((g) => g.dhtKey == dhtKey);
    _groupMessages.remove(dhtKey);
    _groupRelay.disconnect('grp:$dhtKey');
    await _persist();
    notifyListeners();
  }

  Group? getGroup(String dhtKey) {
    try {
      return _groups.firstWhere((g) => g.dhtKey == dhtKey);
    } catch (_) {
      return null;
    }
  }

  bool isAdmin(String dhtKey, String publicKey) {
    final group = getGroup(dhtKey);
    if (group == null) return false;
    try {
      return group.members.firstWhere((m) => m.publicKey == publicKey).role == GroupRole.admin;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_groupsKey, jsonEncode(_groups.map((g) => g.toJson()).toList()));
  }

  Future<void> _persistMessages(String dhtKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final msgs = _groupMessages[dhtKey] ?? [];
      await prefs.setString('$_msgPrefix$dhtKey', jsonEncode(msgs.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }
}
