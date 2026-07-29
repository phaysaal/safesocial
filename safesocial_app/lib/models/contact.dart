import 'package:equatable/equatable.dart';

/// A contact in the user's address book, identified by public key.
class Contact with EquatableMixin {
  /// Ed25519 identity key, hex. How this contact is addressed and verified.
  final String publicKey;

  /// X25519 key-exchange public key, hex.
  ///
  /// Required to derive a pairwise secret with this contact. Null means we
  /// have not learned it yet (added before Phase 1, or from an invite that
  /// predates it) — messages to them cannot be encrypted until it arrives via
  /// a handshake or profile fetch.
  final String? keyExchangePublicKey;

  final String displayName;
  final String? nickname;
  final DateTime addedAt;
  final bool blocked;
  final bool muted;
  final bool following;
  final bool isPending;
  final String? feedDhtKey;

  const Contact({
    required this.publicKey,
    this.keyExchangePublicKey,
    required this.displayName,
    this.nickname,
    required this.addedAt,
    this.blocked = false,
    this.muted = false,
    this.following = true,
    this.isPending = false,
    this.feedDhtKey,
  });

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      publicKey: json['publicKey'] as String,
      keyExchangePublicKey: json['keyExchangePublicKey'] as String?,
      displayName: json['displayName'] as String,
      nickname: json['nickname'] as String?,
      addedAt: DateTime.parse(json['addedAt'] as String),
      blocked: json['blocked'] as bool? ?? false,
      muted: json['muted'] as bool? ?? false,
      following: json['following'] as bool? ?? true,
      isPending: json['isPending'] as bool? ?? false,
      feedDhtKey: json['feedDhtKey'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'publicKey': publicKey,
      'keyExchangePublicKey': keyExchangePublicKey,
      'displayName': displayName,
      'nickname': nickname,
      'addedAt': addedAt.toIso8601String(),
      'blocked': blocked,
      'muted': muted,
      'following': following,
      'isPending': isPending,
      'feedDhtKey': feedDhtKey,
    };
  }

  Contact copyWith({
    String? publicKey,
    String? keyExchangePublicKey,
    String? displayName,
    String? nickname,
    DateTime? addedAt,
    bool? blocked,
    bool? muted,
    bool? following,
    bool? isPending,
    String? feedDhtKey,
  }) {
    return Contact(
      publicKey: publicKey ?? this.publicKey,
      keyExchangePublicKey: keyExchangePublicKey ?? this.keyExchangePublicKey,
      displayName: displayName ?? this.displayName,
      nickname: nickname ?? this.nickname,
      addedAt: addedAt ?? this.addedAt,
      blocked: blocked ?? this.blocked,
      muted: muted ?? this.muted,
      following: following ?? this.following,
      isPending: isPending ?? this.isPending,
      feedDhtKey: feedDhtKey ?? this.feedDhtKey,
    );
  }

  @override
  List<Object?> get props => [
        publicKey,
        keyExchangePublicKey,
        displayName,
        nickname,
        addedAt,
        blocked,
        muted,
        following,
        isPending,
        feedDhtKey,
      ];
}
