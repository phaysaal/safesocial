import 'package:equatable/equatable.dart';

/// A contact in the user's address book, identified by public key.
class Contact with EquatableMixin {
  final String publicKey;
  final String displayName;
  final String? nickname;
  final DateTime addedAt;
  final bool blocked;
  final bool muted;
  final bool following;
  final bool closeFriend;
  final bool isPending;
  final String? feedDhtKey;

  const Contact({
    required this.publicKey,
    required this.displayName,
    this.nickname,
    required this.addedAt,
    this.blocked = false,
    this.muted = false,
    this.following = true,
    this.closeFriend = false,
    this.isPending = false,
    this.feedDhtKey,
  });

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      publicKey: json['publicKey'] as String,
      displayName: json['displayName'] as String,
      nickname: json['nickname'] as String?,
      addedAt: DateTime.parse(json['addedAt'] as String),
      blocked: json['blocked'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      following: json['following'] as bool? ?? true,
      closeFriend: json['closeFriend'] as bool? ?? false,
      isPending: json['isPending'] as bool? ?? false,
      feedDhtKey: json['feedDhtKey'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'displayName': displayName,
      'nickname': nickname,
      'addedAt': addedAt.toIso8601String(),
      'blocked': blocked,
      'muted': muted,
      'following': following,
      'closeFriend': closeFriend,
      'isPending': isPending,
      'feedDhtKey': feedDhtKey,
    };
  }

  Contact copyWith({
    String? publicKey,
    String? displayName,
    String? nickname,
    DateTime? addedAt,
    bool? blocked,
    bool? muted,
    bool? following,
    bool? closeFriend,
    bool? isPending,
    String? feedDhtKey,
  }) {
    return Contact(
      publicKey: publicKey ?? this.publicKey,
      displayName: displayName ?? this.displayName,
      nickname: nickname ?? this.nickname,
      addedAt: addedAt ?? this.addedAt,
      blocked: blocked ?? this.blocked,
      muted: muted ?? this.muted,
      following: following ?? this.following,
      closeFriend: closeFriend ?? this.closeFriend,
      isPending: isPending ?? this.isPending,
      feedDhtKey: feedDhtKey ?? this.feedDhtKey,
    );
  }

  @override
  List<Object?> get props => [
        publicKey,
        displayName,
        nickname,
        addedAt,
        blocked,
        muted,
        following,
        closeFriend,
        isPending,
        feedDhtKey,
      ];
}
