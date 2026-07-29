import 'package:equatable/equatable.dart';

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

  UserProfile({
    required this.publicKey,
    this.keyExchangePublicKey,
    required this.displayName,
    required this.bio,
    this.avatarRef,
    required this.updatedAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      publicKey: json['publicKey'] as String,
      keyExchangePublicKey: json['keyExchangePublicKey'] as String?,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String,
      avatarRef: json['avatarRef'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
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
    };
  }

  UserProfile copyWith({
    String? publicKey,
    String? keyExchangePublicKey,
    String? displayName,
    String? bio,
    String? avatarRef,
    DateTime? updatedAt,
  }) {
    return UserProfile(
      publicKey: publicKey ?? this.publicKey,
      keyExchangePublicKey: keyExchangePublicKey ?? this.keyExchangePublicKey,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarRef: avatarRef ?? this.avatarRef,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props =>
      [publicKey, keyExchangePublicKey, displayName, bio, avatarRef, updatedAt];
}
