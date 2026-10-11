import '../models/profile_about.dart';
import '../models/user_profile.dart';

/// Builds the copy of our profile that one contact receives.
///
/// Every field has an audience; a contact gets a field when they are in it,
/// judged by the spheres they share with us. The name and the picture always
/// travel. Nothing here touches the network: it is the one function that
/// decides what each person may know, kept pure so a test can hold it to
/// account.
class ProfileSharing {
  ProfileSharing._();

  /// The fields a contact sharing [sharedSpheres] with us may see.
  static Set<String> visibleFields(UserProfile profile, Set<String> sharedSpheres) => {
        for (final f in ProfileField.all)
          if ((profile.audience[f] ?? FieldAudience.contacts).allows(sharedSpheres)) f,
      };

  /// [avatarRef], [coverRef] and [featuredRefs] are relay references, already
  /// uploaded once for the whole broadcast.
  static Map<String, dynamic> payloadFor({
    required UserProfile profile,
    required String peer,
    required Set<String> sharedSpheres,
    String? avatarRef,
    String? coverRef,
    List<String> featuredRefs = const [],
  }) {
    final fields = visibleFields(profile, sharedSpheres);
    bool may(String field) => fields.contains(field);
    final about = profile.about.restrictedTo(fields);

    return {
      'name': profile.displayName,
      if (may(ProfileField.bio)) 'bio': profile.bio,
      if (avatarRef != null) 'avatar': avatarRef,
      if (profile.birthday != null && may(ProfileField.birthday))
        'birthday': profile.birthday,
      if (coverRef != null && may(ProfileField.cover)) 'cover': coverRef,
      if (featuredRefs.isNotEmpty && may(ProfileField.featured))
        'featured': featuredRefs,
      if (!about.isEmpty) 'about': about.toJson(),
      if (profile.pinnedPostIds.isNotEmpty && may(ProfileField.pinned))
        'pinned': profile.pinnedPostIds,
      // The legacy contact learns it from us, and only they do.
      if (profile.legacyContact == peer) 'legacy': true,
    };
  }
}
