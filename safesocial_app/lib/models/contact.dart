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

  /// The relay this contact listens on, if it is not ours.
  ///
  /// Federation: everyone listens on their own relay and sends to their
  /// contact's. Learned from the signed prekey bundle or the handshake; null
  /// means "same relay as us", which is also what older contacts have.
  final String? relayHost;

  /// X25519 keys of every device this contact uses, from their signed device
  /// list. Empty means they have published none and [keyExchangePublicKey] is
  /// their only device.
  final List<String> deviceKeys;

  /// Version of the device list [deviceKeys] came from, so an older list
  /// cannot roll a newer one back.
  final int devicesVersion;

  /// The safety number the user confirmed out of band, if they did. Compared
  /// against the current one: equal means verified, different means their
  /// keys changed since.
  final String? verifiedFingerprint;

  /// Their avatar, as a local path once fetched, and birthday as MM-DD, both
  /// from their signed profile message. Shared with contacts only.
  final String? avatarRef;
  final String? birthday;

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
    this.relayHost,
    this.deviceKeys = const [],
    this.devicesVersion = 0,
    this.verifiedFingerprint,
    this.avatarRef,
    this.birthday,
  });

  /// Every device key to seal to.
  List<String> get allDeviceKeys => deviceKeys.isNotEmpty
      ? deviceKeys
      : (keyExchangePublicKey == null ? const [] : [keyExchangePublicKey!]);

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
      relayHost: json['relayHost'] as String?,
      deviceKeys: (json['deviceKeys'] as List<dynamic>?)?.cast<String>() ?? const [],
      devicesVersion: json['devicesVersion'] as int? ?? 0,
      verifiedFingerprint: json['verifiedFingerprint'] as String?,
      avatarRef: json['avatarRef'] as String?,
      birthday: json['birthday'] as String?,
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
      'relayHost': relayHost,
      if (deviceKeys.isNotEmpty) 'deviceKeys': deviceKeys,
      if (devicesVersion != 0) 'devicesVersion': devicesVersion,
      if (verifiedFingerprint != null) 'verifiedFingerprint': verifiedFingerprint,
      if (avatarRef != null) 'avatarRef': avatarRef,
      if (birthday != null) 'birthday': birthday,
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
    String? relayHost,
    List<String>? deviceKeys,
    int? devicesVersion,
    String? verifiedFingerprint,
    bool clearVerified = false,
    String? avatarRef,
    String? birthday,
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
      relayHost: relayHost ?? this.relayHost,
      deviceKeys: deviceKeys ?? this.deviceKeys,
      devicesVersion: devicesVersion ?? this.devicesVersion,
      verifiedFingerprint:
          clearVerified ? null : (verifiedFingerprint ?? this.verifiedFingerprint),
      avatarRef: avatarRef ?? this.avatarRef,
      birthday: birthday ?? this.birthday,
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
        relayHost,
        deviceKeys,
        devicesVersion,
        verifiedFingerprint,
        avatarRef,
        birthday,
      ];
}
