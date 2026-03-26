import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';
import '../models/message.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Manages groups with relay-based group messaging.
///
/// Each group has a relay room (keyed by group dhtKey). All members
/// connect to the same room. Messages broadcast to all members.
class GroupService extends ChangeNotifier {
  static const _groupsKey = 'spheres_groups';
  static const _msgPrefix = 'spheres_group_msgs_';

  List<Group> _groups = [];
  final Map<String, List<Message>> _groupMessages = {};
  final RelayService _groupRelay = RelayService();
  String? _myPublicKey;

  List<Group> get groups => List.unmodifiable(_groups);
  Map<String, List<Message>> get groupMessages => Map.unmodifiable(_groupMessages);

  /// Initialize group messaging relay.
  void initSync(String myPublicKey) {
    _myPublicKey = myPublicKey;
    _groupRelay.onMessageReceived = (groupKey, data) {
      _handleGroupMessage(groupKey, data);
    };

    // Connect to relay rooms for all groups
    for (final group in _groups) {
      _groupRelay.connect('grp:$myPublicKey', 'grp:${group.dhtKey}');
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

    // Load cached messages
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

    // Connect to group relay room
    if (_myPublicKey != null) {
      _groupRelay.connect('grp:$_myPublicKey', 'grp:$dhtKey');
    }
  }

  Future<void> deleteGroup(String dhtKey) async {
    _groups.removeWhere((g) => g.dhtKey == dhtKey);
    _groupMessages.remove(dhtKey);
    _groupRelay.disconnect('grp:$dhtKey');
    await _persist();
    notifyListeners();
  }

  Future<void> updateGroup(String dhtKey, {String? name, String? description}) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;
    _groups[index] = _groups[index].copyWith(name: name, description: description);
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

  Future<void> promoteMember(String dhtKey, String publicKey) async =>
      _changeMemberRole(dhtKey, publicKey, GroupRole.admin);

  Future<void> demoteMember(String dhtKey, String publicKey) async =>
      _changeMemberRole(dhtKey, publicKey, GroupRole.member);

  Future<void> _changeMemberRole(String dhtKey, String publicKey, GroupRole role) async {
    final gi = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (gi == -1) return;
    final group = _groups[gi];
    final mi = group.members.indexWhere((m) => m.publicKey == publicKey);
    if (mi == -1) return;
    final updated = List<GroupMember>.from(group.members);
    updated[mi] = updated[mi].copyWith(role: role);
    _groups[gi] = group.copyWith(members: updated);
    await _persist();
    notifyListeners();
  }

  Future<void> leaveGroup(String dhtKey, String publicKey) async {
    await removeMember(dhtKey, publicKey);
    final group = getGroup(dhtKey);
    if (group != null && group.members.isEmpty) {
      _groups.removeWhere((g) => g.dhtKey == dhtKey);
      _groupMessages.remove(dhtKey);
      await _persist();
      notifyListeners();
    }
  }

  /// Send a message to a group — broadcasts via relay to all members.
  Future<void> sendGroupMessage(String dhtKey, String senderId, String content) async {
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

    // Broadcast via relay
    final payload = jsonEncode({
      'type': 'group_msg',
      'group_id': dhtKey,
      'message': message.toJson(),
    });
    _groupRelay.sendViaRelay('grp:$dhtKey', payload);
    DebugLogService().info('Group', 'Message sent to group $dhtKey');

    await _persistMessages(dhtKey);
  }

  void _handleGroupMessage(String groupKey, String data) {
    try {
      final payload = jsonDecode(data) as Map<String, dynamic>;
      if (payload['type'] != 'group_msg') return;

      final groupId = payload['group_id'] as String;
      final msgData = payload['message'] as Map<String, dynamic>;
      final message = Message.fromJson(msgData);

      // Skip own messages and duplicates
      if (message.senderId == _myPublicKey || message.senderId == 'self') return;
      if (_groupMessages[groupId]?.any((m) => m.id == message.id) ?? false) return;

      _groupMessages.putIfAbsent(groupId, () => []);
      _groupMessages[groupId]!.add(message);
      DebugLogService().success('Group', 'Received group message in $groupId');
      notifyListeners();
      _persistMessages(groupId);
    } catch (e) {
      DebugLogService().error('Group', 'Failed to handle group message: $e');
    }
  }

  List<Message> getGroupMessages(String dhtKey) => _groupMessages[dhtKey] ?? [];

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
      await prefs.setString(
        '$_msgPrefix$dhtKey',
        jsonEncode(msgs.map((m) => m.toJson()).toList()),
      );
    } catch (_) {}
  }
}
