import 'package:equatable/equatable.dart';

/// What a member may do in a sphere.
///
/// Owner is separate from admin because "who can hand over the keys" and "who
/// can kick people" are different questions. An owner has every admin power
/// plus the two that decide the sphere's fate: transferring ownership, and
/// demoting an admin. Exactly one member holds it.
enum SphereRole { owner, admin, member }

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

  /// True for owners too: an owner can do everything an admin can.
  bool get isAdmin => role == SphereRole.admin || role == SphereRole.owner;

  bool get isOwner => role == SphereRole.owner;

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
        role: roleFromName(json['role']),
        joinedAt: DateTime.parse(json['joinedAt'] as String),
        invitedBy: json['invitedBy'] as String? ?? '',
      );

  /// Unknown names fall back to [SphereRole.member], the least privileged
  /// reading — a client that does not understand a future role must not
  /// accidentally grant it.
  static SphereRole roleFromName(dynamic name) {
    for (final role in SphereRole.values) {
      if (role.name == name) return role;
    }
    return SphereRole.member;
  }

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

  /// Free text shown on the sphere's page. Empty by default.
  final String description;

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
    this.description = '',
  });

  bool contains(String identityKey) =>
      members.any((m) => m.identityKey == identityKey);

  bool isAdmin(String identityKey) =>
      members.any((m) => m.identityKey == identityKey && m.isAdmin);

  bool isOwner(String identityKey) =>
      members.any((m) => m.identityKey == identityKey && m.isOwner);

  /// The owner's identity key, or null if the sphere has none.
  ///
  /// Null is a real state, not a bug: if the owner is removed from a member
  /// list by a client that predates this role, or leaves in a way this version
  /// cannot express, the sphere carries on with admins and no owner. Callers
  /// must handle it rather than assume.
  String? get ownerKey {
    for (final member in members) {
      if (member.isOwner) return member.identityKey;
    }
    return null;
  }

  List<SphereMember> get admins =>
      members.where((m) => m.isAdmin).toList(growable: false);

  /// Who inherits if the owner walks away, chosen without anyone negotiating:
  /// the longest-serving admin, or failing that the longest-serving member.
  ///
  /// Determinism is the point. Every device computes the same answer from the
  /// same member list, so an owner leaving cannot leave members disagreeing
  /// about who is in charge. Ties break on the identity key, which is unique.
  String? successorAfter(String leavingKey) {
    final candidates =
        members.where((m) => m.identityKey != leavingKey).toList();
    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
      final byJoin = a.joinedAt.compareTo(b.joinedAt);
      if (byJoin != 0) return byJoin;
      return a.identityKey.compareTo(b.identityKey);
    });
    return candidates.first.identityKey;
  }

  /// A member list with exactly one owner.
  ///
  /// Spheres created before the role existed have only admins. Rather than
  /// migrate them with a message every device would have to receive, each
  /// device derives the same answer locally: the creator is the owner if they
  /// are still a member. Deterministic, so nobody ends up disagreeing.
  static List<SphereMember> normaliseOwnership(
    List<SphereMember> members,
    String createdBy,
  ) {
    final owners = members.where((m) => m.isOwner).toList();
    if (owners.length == 1) return members;

    if (owners.isEmpty) {
      if (!members.any((m) => m.identityKey == createdBy)) return members;
      return members
          .map((m) => m.identityKey == createdBy
              ? m.copyWith(role: SphereRole.owner)
              : m)
          .toList();
    }

    // More than one owner can only come from a malformed or hostile op. Keep
    // the creator if they are among them, otherwise the lowest key — any rule
    // works provided every device applies the same one.
    final keep = owners.any((m) => m.identityKey == createdBy)
        ? createdBy
        : (owners.map((m) => m.identityKey).toList()..sort()).first;
    return members
        .map((m) => m.isOwner && m.identityKey != keep
            ? m.copyWith(role: SphereRole.admin)
            : m)
        .toList();
  }

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
    String? description,
    int? epoch,
    List<SphereMember>? members,
  }) =>
      Sphere(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        kind: kind,
        createdBy: createdBy,
        createdAt: createdAt,
        epoch: epoch ?? this.epoch,
        members: members ?? this.members,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
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
    final createdBy = json['createdBy'] as String;
    return Sphere(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      kind: kind,
      createdBy: createdBy,
      createdAt: DateTime.parse(json['createdAt'] as String),
      epoch: json['epoch'] as int,
      members: normaliseOwnership(
        (json['members'] as List<dynamic>)
            .map((m) => SphereMember.fromJson(m as Map<String, dynamic>))
            .toList(),
        createdBy,
      ),
    );
  }

  @override
  List<Object?> get props =>
      [id, name, description, kind, createdBy, createdAt, epoch, members];
}
