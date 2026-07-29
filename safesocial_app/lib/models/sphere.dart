import 'package:equatable/equatable.dart';

/// What a member may do in a sphere.
enum SphereRole { admin, member }

/// How a sphere is presented. Not a security boundary — every sphere is the
/// same primitive underneath, and access is decided by membership alone.
enum SphereKind {
  /// Two members, rendered as a conversation.
  direct,

  /// Many members, all of whom can post.
  group,

  /// Many members, but only admins post. Still member-scoped: this is not a
  /// public audience, and there is no code path that creates one.
  broadcast,
}

class SphereMember with EquatableMixin {
  /// Ed25519 identity key, hex.
  final String identityKey;
  final SphereRole role;
  final DateTime joinedAt;

  /// Who added them, for auditability of membership changes.
  final String invitedBy;

  const SphereMember({
    required this.identityKey,
    required this.role,
    required this.joinedAt,
    required this.invitedBy,
  });

  bool get isAdmin => role == SphereRole.admin;

  SphereMember copyWith({SphereRole? role}) => SphereMember(
        identityKey: identityKey,
        role: role ?? this.role,
        joinedAt: joinedAt,
        invitedBy: invitedBy,
      );

  Map<String, dynamic> toJson() => {
        'identityKey': identityKey,
        'role': role.name,
        'joinedAt': joinedAt.toIso8601String(),
        'invitedBy': invitedBy,
      };

  static SphereMember fromJson(Map<String, dynamic> json) => SphereMember(
        identityKey: json['identityKey'] as String,
        role: json['role'] == 'admin' ? SphereRole.admin : SphereRole.member,
        joinedAt: DateTime.parse(json['joinedAt'] as String),
        invitedBy: json['invitedBy'] as String? ?? '',
      );

  @override
  List<Object?> get props => [identityKey, role, joinedAt, invitedBy];
}

/// A named, member-scoped context. The only container in Spheres.
///
/// Everything the product does happens inside one of these: a direct message
/// is a sphere of two, a group chat is a sphere of many, a "close friends"
/// audience is a sphere you post into, and an album is content within one.
///
/// This replaces five parallel subsystems — contacts-as-audience, groups,
/// rings, albums, and `PostAudience` — each of which had its own membership
/// notion, its own key derivation and its own bugs. Collapsing them is what
/// makes "no public audience" structural: content that is not addressed to a
/// sphere cannot be created, so there is no unscoped path to forget to check.
class Sphere with EquatableMixin {
  /// Random 256-bit id, hex.
  ///
  /// Deliberately not derived from the member set, so it survives membership
  /// changes, and not sequential, so it cannot be guessed or enumerated.
  final String id;

  final String name;
  final SphereKind kind;
  final String createdBy;
  final DateTime createdAt;

  /// Increments on every membership change. The sphere key is rotated with it,
  /// so a removed member holds a key that no longer opens new content.
  final int epoch;

  final List<SphereMember> members;

  const Sphere({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdBy,
    required this.createdAt,
    required this.epoch,
    required this.members,
  });

  bool contains(String identityKey) =>
      members.any((m) => m.identityKey == identityKey);

  bool isAdmin(String identityKey) =>
      members.any((m) => m.identityKey == identityKey && m.isAdmin);

  SphereMember? memberFor(String identityKey) {
    for (final member in members) {
      if (member.identityKey == identityKey) return member;
    }
    return null;
  }

  /// Everyone except us — the set a key has to be wrapped for.
  List<String> othersThan(String myIdentityKey) => members
      .where((m) => m.identityKey != myIdentityKey)
      .map((m) => m.identityKey)
      .toList();

  Sphere copyWith({
    String? name,
    int? epoch,
    List<SphereMember>? members,
  }) =>
      Sphere(
        id: id,
        name: name ?? this.name,
        kind: kind,
        createdBy: createdBy,
        createdAt: createdAt,
        epoch: epoch ?? this.epoch,
        members: members ?? this.members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'epoch': epoch,
        'members': members.map((m) => m.toJson()).toList(),
      };

  static Sphere fromJson(Map<String, dynamic> json) {
    SphereKind kind = SphereKind.group;
    for (final candidate in SphereKind.values) {
      if (candidate.name == json['kind']) kind = candidate;
    }
    return Sphere(
      id: json['id'] as String,
      name: json['name'] as String,
      kind: kind,
      createdBy: json['createdBy'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      epoch: json['epoch'] as int,
      members: (json['members'] as List<dynamic>)
          .map((m) => SphereMember.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  List<Object?> get props => [id, name, kind, createdBy, createdAt, epoch, members];
}
