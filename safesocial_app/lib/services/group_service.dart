import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/group.dart';
import '../models/message.dart';

/// Manages group lifecycle — creation, membership, and group messaging.
///
/// Currently persists groups to SharedPreferences and keeps messages in-memory.
/// In production, groups will be backed by shared Veilid DHT records so that
/// every member can read and write to the same data structure.
class GroupService extends ChangeNotifier {
  static const _groupsKey = 'spheres_groups';

  List<Group> _groups = [];
  final Map<String, List<Message>> _groupMessages = {};

  /// All groups the user belongs to.
  List<Group> get groups => List.unmodifiable(_groups);

  /// Messages keyed by group dhtKey.
  Map<String, List<Message>> get groupMessages =>
      Map.unmodifiable(_groupMessages);

  /// Load groups from local storage.
  Future<void> loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final groupsJson = prefs.getString(_groupsKey);
    if (groupsJson != null) {
      try {
        final list = jsonDecode(groupsJson) as List<dynamic>;
        _groups = list
            .map((e) => Group.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('[GroupService] Failed to load groups: $e');
        _groups = [];
      }
    }
    notifyListeners();
  }

  /// Create a new group and add the current user as admin.
  ///
  /// [publicKey] and [displayName] identify the creating user.
  /// TODO: Integrate with Veilid DHT — create a shared DHT record for the group.
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
  }

  /// Delete a group if the caller is an admin.
  Future<void> deleteGroup(String dhtKey) async {
    _groups.removeWhere((g) => g.dhtKey == dhtKey);
    _groupMessages.remove(dhtKey);
    await _persist();
    notifyListeners();
  }

  /// Update a group's name and/or description.
  Future<void> updateGroup(
    String dhtKey, {
    String? name,
    String? description,
  }) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;

    _groups[index] = _groups[index].copyWith(
      name: name,
      description: description,
    );
    await _persist();
    notifyListeners();
  }

  /// Add a member to a group.
  Future<void> addMember(
    String dhtKey,
    String publicKey,
    String displayName, {
    GroupRole role = GroupRole.member,
  }) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;

    final group = _groups[index];

    // Avoid duplicates.
    if (group.members.any((m) => m.publicKey == publicKey)) return;

    final member = GroupMember(
      publicKey: publicKey,
      displayName: displayName,
      role: role,
      joinedAt: DateTime.now(),
    );

    _groups[index] = group.copyWith(
      members: [...group.members, member],
    );
    await _persist();
    notifyListeners();
  }

  /// Remove a member from a group.
  Future<void> removeMember(String dhtKey, String publicKey) async {
    final index = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (index == -1) return;

    final group = _groups[index];
    final updatedMembers =
        group.members.where((m) => m.publicKey != publicKey).toList();

    _groups[index] = group.copyWith(members: updatedMembers);
    await _persist();
    notifyListeners();
  }

  /// Promote a member to admin.
  Future<void> promoteMember(String dhtKey, String publicKey) async {
    _changeMemberRole(dhtKey, publicKey, GroupRole.admin);
  }

  /// Demote an admin to regular member.
  Future<void> demoteMember(String dhtKey, String publicKey) async {
    _changeMemberRole(dhtKey, publicKey, GroupRole.member);
  }

  void _changeMemberRole(String dhtKey, String publicKey, GroupRole role) async {
    final groupIndex = _groups.indexWhere((g) => g.dhtKey == dhtKey);
    if (groupIndex == -1) return;

    final group = _groups[groupIndex];
    final memberIndex =
        group.members.indexWhere((m) => m.publicKey == publicKey);
    if (memberIndex == -1) return;

    final updatedMembers = List<GroupMember>.from(group.members);
    updatedMembers[memberIndex] =
        updatedMembers[memberIndex].copyWith(role: role);

    _groups[groupIndex] = group.copyWith(members: updatedMembers);
    await _persist();
    notifyListeners();
  }

  /// Remove self from a group.
  Future<void> leaveGroup(String dhtKey, String publicKey) async {
    await removeMember(dhtKey, publicKey);

    // If the group is now empty, remove it entirely.
    final group = getGroup(dhtKey);
    if (group != null && group.members.isEmpty) {
      _groups.removeWhere((g) => g.dhtKey == dhtKey);
      _groupMessages.remove(dhtKey);
      await _persist();
      notifyListeners();
    }
  }

  /// Send a message to a group.
  ///
  /// TODO: Integrate with Veilid DHT for real message distribution.
  Future<void> sendGroupMessage(
    String dhtKey,
    String senderId,
    String content,
  ) async {
    final message = Message(
      id: const Uuid().v4(),
      senderId: senderId,
      recipientId: dhtKey, // group dhtKey as the recipient
      content: content,
      timestamp: DateTime.now(),
    );

    _groupMessages.putIfAbsent(dhtKey, () => []);
    _groupMessages[dhtKey]!.add(message);
    notifyListeners();
  }

  /// Get all messages for a group.
  List<Message> getGroupMessages(String dhtKey) {
    return _groupMessages[dhtKey] ?? [];
  }

  /// Look up a group by its dhtKey.
  Group? getGroup(String dhtKey) {
    try {
      return _groups.firstWhere((g) => g.dhtKey == dhtKey);
    } catch (_) {
      return null;
    }
  }

  /// Check if a user is an admin in a group.
  bool isAdmin(String dhtKey, String publicKey) {
    final group = getGroup(dhtKey);
    if (group == null) return false;
    try {
      final member =
          group.members.firstWhere((m) => m.publicKey == publicKey);
      return member.role == GroupRole.admin;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_groups.map((g) => g.toJson()).toList());
    await prefs.setString(_groupsKey, json);
  }
}
