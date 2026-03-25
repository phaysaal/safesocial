import 'package:equatable/equatable.dart';

/// Roles a member can hold in a group.
enum GroupRole { admin, member }

/// A peer-to-peer group backed by a shared DHT record.
class Group with EquatableMixin {
  final String dhtKey;
  final String name;
  final String description;
  final String createdBy;
  final DateTime createdAt;
  final List<GroupMember> members;

  const Group({
    required this.dhtKey,
    required this.name,
    required this.description,
    required this.createdBy,
    required this.createdAt,
    this.members = const [],
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      dhtKey: json['dhtKey'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      createdBy: json['createdBy'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      members: (json['members'] as List<dynamic>?)
              ?.map((e) => GroupMember.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dhtKey': dhtKey,
      'name': name,
      'description': description,
      'createdBy': createdBy,
      'createdAt': createdAt.toIso8601String(),
      'members': members.map((m) => m.toJson()).toList(),
    };
  }

  Group copyWith({
    String? dhtKey,
    String? name,
    String? description,
    String? createdBy,
    DateTime? createdAt,
    List<GroupMember>? members,
  }) {
    return Group(
      dhtKey: dhtKey ?? this.dhtKey,
      name: name ?? this.name,
      description: description ?? this.description,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      members: members ?? this.members,
    );
  }

  @override
  List<Object?> get props =>
      [dhtKey, name, description, createdBy, createdAt, members];
}

/// A member within a group.
class GroupMember with EquatableMixin {
  final String publicKey;
  final String displayName;
  final GroupRole role;
  final DateTime joinedAt;

  const GroupMember({
    required this.publicKey,
    required this.displayName,
    required this.role,
    required this.joinedAt,
  });

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    return GroupMember(
      publicKey: json['publicKey'] as String,
      displayName: json['displayName'] as String,
      role: GroupRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => GroupRole.member,
      ),
      joinedAt: DateTime.parse(json['joinedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'displayName': displayName,
      'role': role.name,
      'joinedAt': joinedAt.toIso8601String(),
    };
  }

  GroupMember copyWith({
    String? publicKey,
    String? displayName,
    GroupRole? role,
    DateTime? joinedAt,
  }) {
    return GroupMember(
      publicKey: publicKey ?? this.publicKey,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }

  @override
  List<Object?> get props => [publicKey, displayName, role, joinedAt];
}
