import 'package:equatable/equatable.dart';

/// Represents a user's public profile in the SafeSocial network.
class UserProfile with EquatableMixin {
  final String publicKey;
  final String displayName;
  final String bio;
  final String? avatarRef;
  final DateTime updatedAt;

  UserProfile({
    required this.publicKey,
    required this.displayName,
    required this.bio,
    this.avatarRef,
    required this.updatedAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      publicKey: json['publicKey'] as String,
      displayName: json['displayName'] as String,
      bio: json['bio'] as String,
      avatarRef: json['avatarRef'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'displayName': displayName,
      'bio': bio,
      'avatarRef': avatarRef,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  UserProfile copyWith({
    String? publicKey,
    String? displayName,
    String? bio,
    String? avatarRef,
    DateTime? updatedAt,
  }) {
    return UserProfile(
      publicKey: publicKey ?? this.publicKey,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarRef: avatarRef ?? this.avatarRef,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => [publicKey, displayName, bio, avatarRef, updatedAt];
}
