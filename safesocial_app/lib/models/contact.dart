import 'package:equatable/equatable.dart';

import 'profile_about.dart';

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
  final String bio;

  /// What else they told us about themselves, already cut to what they
  /// decided we may see, and their cover and featured photos as local paths.
  final ProfileAbout about;
  final String? coverRef;
  final List<String> featuredRefs;

  /// They named us their legacy contact.
  final bool namedMeLegacy;

  /// Local choices about this person. Restricted: they get only our name and
  /// picture from the profile. Favourite: their posts make the favourites
  /// feed. On a break: quiet and restricted until we end it. Snoozed: quiet
  /// until the date. None of these is ever told to them.
  final bool restricted;
  final bool favourite;
  final bool onBreak;
  final DateTime? snoozedUntil;

  /// Posts they pinned to their profile, by id; shown if we have them.
  final List<String> pinnedPostIds;

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
    this.bio = '',
    this.about = ProfileAbout.empty,
    this.coverRef,
    this.featuredRefs = const [],
    this.namedMeLegacy = false,
    this.pinnedPostIds = const [],
    this.restricted = false,
    this.favourite = false,
    this.onBreak = false,
    this.snoozedUntil,
  });

  bool get isSnoozed =>
      snoozedUntil != null && DateTime.now().isBefore(snoozedUntil!);

  /// Their posts stay out of our feed and they do not notify us.
  bool get isQuiet => muted || onBreak || isSnoozed;

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
      bio: json['bio'] is String ? json['bio'] as String : '',
      about: json['about'] is Map
          ? ProfileAbout.fromJson((json['about'] as Map).cast<String, dynamic>())
          : ProfileAbout.empty,
      coverRef: json['coverRef'] as String?,
      featuredRefs:
          (json['featuredRefs'] as List<dynamic>?)?.whereType<String>().toList() ??
              const [],
      namedMeLegacy: json['namedMeLegacy'] == true,
      restricted: json['restricted'] == true,
      favourite: json['favourite'] == true,
      onBreak: json['onBreak'] == true,
      snoozedUntil: json['snoozedUntil'] is String
          ? DateTime.tryParse(json['snoozedUntil'] as String)
          : null,
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
      if (bio.isNotEmpty) 'bio': bio,
      if (!about.isEmpty) 'about': about.toJson(),
      if (coverRef != null) 'coverRef': coverRef,
      if (featuredRefs.isNotEmpty) 'featuredRefs': featuredRefs,
      if (namedMeLegacy) 'namedMeLegacy': true,
      if (restricted) 'restricted': true,
      if (favourite) 'favourite': true,
      if (onBreak) 'onBreak': true,
      if (snoozedUntil != null) 'snoozedUntil': snoozedUntil!.toIso8601String(),
      if (pinnedPostIds.isNotEmpty) 'pinnedPostIds': pinnedPostIds,
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
    bool clearBirthday = false,
    String? bio,
    ProfileAbout? about,
    String? coverRef,
    bool clearCover = false,
    List<String>? featuredRefs,
    bool? namedMeLegacy,
    List<String>? pinnedPostIds,
    bool? restricted,
    bool? favourite,
    bool? onBreak,
    DateTime? snoozedUntil,
    bool clearSnooze = false,
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
      birthday: clearBirthday ? null : (birthday ?? this.birthday),
      bio: bio ?? this.bio,
      about: about ?? this.about,
      coverRef: clearCover ? null : (coverRef ?? this.coverRef),
      featuredRefs: featuredRefs ?? this.featuredRefs,
      namedMeLegacy: namedMeLegacy ?? this.namedMeLegacy,
      pinnedPostIds: pinnedPostIds ?? this.pinnedPostIds,
      restricted: restricted ?? this.restricted,
      favourite: favourite ?? this.favourite,
      onBreak: onBreak ?? this.onBreak,
      snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
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
        bio,
        about,
        coverRef,
        featuredRefs,
        namedMeLegacy,
        pinnedPostIds,
        restricted,
        favourite,
        onBreak,
        snoozedUntil,
      ];
}
