import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/contact_service.dart';
import '../services/identity_service.dart';

/// The local path of the picture we hold for [identityKey]: our own profile
/// picture for our key, the picture from a contact's signed profile for
/// theirs, null for anyone else. Resolved by the reader, never from the wire,
/// so an old post shows the picture the person has now.
String? avatarRefFor(BuildContext context, String? identityKey) {
  if (identityKey == null || identityKey.isEmpty) return null;
  final identity = context.watch<IdentityService?>();
  if (identity != null && identity.publicKey == identityKey) {
    return identity.currentIdentity?.avatarRef;
  }
  return context.watch<ContactService?>()?.getContact(identityKey)?.avatarRef;
}

/// Avatar size presets.
enum AvatarSize {
  small(16),
  medium(24),
  large(36);

  final double radius;
  const AvatarSize(this.radius);
}

/// Reusable avatar widget that displays an image or initials fallback.
class UserAvatar extends StatelessWidget {
  final String displayName;

  /// A picture to show, as a local path. When null, [identityKey] is looked
  /// up through [avatarRefFor].
  final String? imageRef;

  /// Whose face this is. Lets the widget find the picture itself wherever
  /// the caller only knows the key.
  final String? identityKey;
  final AvatarSize size;

  const UserAvatar({
    super.key,
    required this.displayName,
    this.imageRef,
    this.identityKey,
    this.size = AvatarSize.medium,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final bgColor = _colorFromName(displayName);

    // Show image if we have a local file path
    final ref = imageRef ?? avatarRefFor(context, identityKey);
    if (ref != null && ref.isNotEmpty) {
      final file = File(ref);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: size.radius,
          backgroundImage: FileImage(file),
        );
      }
    }

    // A tonal pair from the name's hue: a soft fill with a deep initial,
    // rather than a saturated disc with white on it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size.radius * 2,
      height: size.radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [bgColor.withValues(alpha: 0.55), bgColor.withValues(alpha: 0.35)]
              : [bgColor.withValues(alpha: 0.28), bgColor.withValues(alpha: 0.16)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: dark ? Colors.white : HSLColor.fromColor(bgColor).withLightness(0.32).toColor(),
          fontWeight: FontWeight.w700,
          fontSize: size.radius * 0.9,
        ),
      ),
    );
  }

  Color _colorFromName(String name) {
    if (name.isEmpty) return const Color(0xFF7B2FBE);
    // Eight hues around the wheel, keyed by the name so it stays the same.
    final hash = name.codeUnits.fold<int>(0, (prev, c) => prev * 31 + c);
    final hue = (hash % 8) * 45.0;
    return HSLColor.fromAHSL(1, hue, 0.62, 0.52).toColor();
  }
}
