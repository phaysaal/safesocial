import 'package:equatable/equatable.dart';

import 'profile_about.dart';

/// Represents a user's public profile in the Sphere network.
class UserProfile with EquatableMixin {
  /// Ed25519 identity key, hex. Signs everything this user sends.
  final String publicKey;

  /// X25519 key-exchange public key, hex.
  ///
  /// Published so contacts can derive a pairwise secret with us. Null for
  /// profiles created before key exchange existed; those contacts cannot be
  /// messaged securely until they publish an updated profile.
  final String? keyExchangePublicKey;

  final String displayName;
  final String bio;
  final String? avatarRef;
  final DateTime updatedAt;

  /// MM-DD. Shared with contacts, never published.
  final String? birthday;

  /// The rest of what the profile says; see [ProfileAbout].
  final ProfileAbout about;

  /// Who sees which field, by [ProfileField] name. A field not listed goes
  /// to all contacts. Local; what travels is the result of applying it.
  final Map<String, FieldAudience> audience;

  /// Cover photo and featured photos, as local media refs.
  final String? coverRef;
  final List<String> featuredRefs;

  /// A temporary picture: the one to go back to, and when. Null when the
  /// current picture is not temporary.
  final String? avatarBefore;
  final DateTime? avatarUntil;

  /// The contact who speaks for this profile if its owner cannot: told that
  /// they are, and suggested as a recovery guardian.
  final String? legacyContact;

  /// Posts pinned to the profile, by id. A contact sees the ones they have.
  final List<String> pinnedPostIds;

  UserProfile({
    required this.publicKey,
    this.keyExchangePublicKey,
    required this.displayName,
    required this.bio,
    this.avatarRef,
    required this.updatedAt,
    this.birthday,
    this.about = ProfileAbout.empty,
    this.audience = const {},
    this.coverRef,
    this.featuredRefs = const [],
    this.avatarBefore,
    this.avatarUntil,
    this.legacyContact,
    this.pinnedPostIds = const [],
  });

  bool get avatarIsTemporary => avatarUntil != null;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      publicKey: json['publicKey'] as String,
      keyExchangePublicKey: json['keyExchangePublicKey'] as String?,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String,
      avatarRef: json['avatarRef'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      birthday: json['birthday'] as String?,
      about: json['about'] is Map
          ? ProfileAbout.fromJson((json['about'] as Map).cast<String, dynamic>())
          : ProfileAbout.empty,
      audience: json['audience'] is Map
          ? (json['audience'] as Map).map(
              (k, v) => MapEntry(k.toString(), FieldAudience.fromJson(v)))
          : const {},
      coverRef: json['coverRef'] as String?,
      featuredRefs:
          (json['featuredRefs'] as List<dynamic>?)?.whereType<String>().toList() ??
              const [],
      avatarBefore: json['avatarBefore'] as String?,
      avatarUntil: json['avatarUntil'] is String
          ? DateTime.tryParse(json['avatarUntil'] as String)
          : null,
      legacyContact: json['legacyContact'] as String?,
      pinnedPostIds:
          (json['pinnedPostIds'] as List<dynamic>?)?.whereType<String>().toList() ??
              const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'keyExchangePublicKey': keyExchangePublicKey,
      'displayName': displayName,
      'bio': bio,
      'avatarRef': avatarRef,
      'updatedAt': updatedAt.toIso8601String(),
      if (birthday != null) 'birthday': birthday,
      if (!about.isEmpty) 'about': about.toJson(),
      if (audience.isNotEmpty)
        'audience': audience.map((k, v) => MapEntry(k, v.toJson())),
      if (coverRef != null) 'coverRef': coverRef,
      if (featuredRefs.isNotEmpty) 'featuredRefs': featuredRefs,
      if (avatarBefore != null) 'avatarBefore': avatarBefore,
      if (avatarUntil != null) 'avatarUntil': avatarUntil!.toIso8601String(),
      if (legacyContact != null) 'legacyContact': legacyContact,
      if (pinnedPostIds.isNotEmpty) 'pinnedPostIds': pinnedPostIds,
    };
  }

  UserProfile copyWith({
    String? publicKey,
    String? keyExchangePublicKey,
    String? displayName,
    String? bio,
    String? avatarRef,
    bool clearAvatar = false,
    DateTime? updatedAt,
    String? birthday,
    bool clearBirthday = false,
    ProfileAbout? about,
    Map<String, FieldAudience>? audience,
    String? coverRef,
    bool clearCover = false,
    List<String>? featuredRefs,
    String? avatarBefore,
    DateTime? avatarUntil,
    bool clearTemporaryAvatar = false,
    String? legacyContact,
    bool clearLegacyContact = false,
    List<String>? pinnedPostIds,
  }) {
    return UserProfile(
      publicKey: publicKey ?? this.publicKey,
      keyExchangePublicKey: keyExchangePublicKey ?? this.keyExchangePublicKey,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarRef: clearAvatar ? null : (avatarRef ?? this.avatarRef),
      updatedAt: updatedAt ?? this.updatedAt,
      birthday: clearBirthday ? null : (birthday ?? this.birthday),
      about: about ?? this.about,
      audience: audience ?? this.audience,
      coverRef: clearCover ? null : (coverRef ?? this.coverRef),
      featuredRefs: featuredRefs ?? this.featuredRefs,
      avatarBefore:
          clearTemporaryAvatar ? null : (avatarBefore ?? this.avatarBefore),
      avatarUntil:
          clearTemporaryAvatar ? null : (avatarUntil ?? this.avatarUntil),
      legacyContact:
          clearLegacyContact ? null : (legacyContact ?? this.legacyContact),
      pinnedPostIds: pinnedPostIds ?? this.pinnedPostIds,
    );
  }

  @override
  List<Object?> get props => [
        publicKey,
        keyExchangePublicKey,
        displayName,
        bio,
        avatarRef,
        updatedAt,
        birthday,
        about,
        audience,
        coverRef,
        featuredRefs,
        avatarBefore,
        avatarUntil,
        legacyContact,
        pinnedPostIds,
      ];
}
