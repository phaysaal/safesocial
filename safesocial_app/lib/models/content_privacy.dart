import 'package:flutter/material.dart';

/// Privacy level for a piece of content (post, photo, video, message).
enum ContentPrivacy {
  /// Only the creator can see this content.
  onlyMe,

  /// Shared with a single specific person.
  individual,

  /// Shared with members of a specific group.
  group,

  /// Anyone can see this content (no encryption).
  public,
}

/// Full privacy setting with optional recipient/group context.
class PrivacySetting {
  final ContentPrivacy level;
  final String? recipientPublicKey;
  final String? recipientName;
  final String? groupId;
  final String? groupName;

  const PrivacySetting({
    required this.level,
    this.recipientPublicKey,
    this.recipientName,
    this.groupId,
    this.groupName,
  });

  static const defaultPublic = PrivacySetting(level: ContentPrivacy.public);
  static const defaultOnlyMe = PrivacySetting(level: ContentPrivacy.onlyMe);

  String get label => switch (level) {
        ContentPrivacy.onlyMe => 'Only Me',
        ContentPrivacy.individual => recipientName ?? 'One Person',
        ContentPrivacy.group => groupName ?? 'Group',
        ContentPrivacy.public => 'Public',
      };

  IconData get icon => switch (level) {
        ContentPrivacy.onlyMe => Icons.lock,
        ContentPrivacy.individual => Icons.person,
        ContentPrivacy.group => Icons.group,
        ContentPrivacy.public => Icons.public,
      };

  Color get color => switch (level) {
        ContentPrivacy.onlyMe => Colors.red,
        ContentPrivacy.individual => Colors.blue,
        ContentPrivacy.group => Colors.purple,
        ContentPrivacy.public => Colors.green,
      };

  String toJson() => switch (level) {
        ContentPrivacy.onlyMe => 'onlyMe',
        ContentPrivacy.individual => 'individual:${recipientPublicKey ?? ''}',
        ContentPrivacy.group => 'group:${groupId ?? ''}',
        ContentPrivacy.public => 'public',
      };

  static PrivacySetting fromJson(String s) {
    if (s == 'onlyMe') return defaultOnlyMe;
    if (s == 'public') return defaultPublic;
    if (s.startsWith('individual:')) {
      return PrivacySetting(
        level: ContentPrivacy.individual,
        recipientPublicKey: s.substring('individual:'.length),
      );
    }
    if (s.startsWith('group:')) {
      return PrivacySetting(
        level: ContentPrivacy.group,
        groupId: s.substring('group:'.length),
      );
    }
    return defaultPublic;
  }
}
