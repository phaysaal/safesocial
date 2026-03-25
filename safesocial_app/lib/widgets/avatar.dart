import 'package:flutter/material.dart';

/// Avatar size presets.
enum AvatarSize {
  small(16),
  medium(24),
  large(36);

  final double radius;
  const AvatarSize(this.radius);
}

/// Reusable avatar widget that displays initials or an image.
///
/// If no image reference is provided, shows a CircleAvatar with the first
/// letter of the display name and a color derived from the name string.
class UserAvatar extends StatelessWidget {
  final String displayName;
  final String? imageRef;
  final AvatarSize size;

  const UserAvatar({
    super.key,
    required this.displayName,
    this.imageRef,
    this.size = AvatarSize.medium,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final bgColor = _colorFromName(displayName);

    // TODO: Support loading images from Veilid block store via imageRef.
    return CircleAvatar(
      radius: size.radius,
      backgroundColor: bgColor,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size.radius * 0.85,
        ),
      ),
    );
  }

  /// Derive a consistent color from a name string.
  Color _colorFromName(String name) {
    if (name.isEmpty) return const Color(0xFF7B2FBE);

    final hash = name.codeUnits.fold<int>(0, (prev, c) => prev + c);
    final colors = [
      const Color(0xFF00D4AA), // teal
      const Color(0xFF7B2FBE), // purple
      const Color(0xFF2196F3), // blue
      const Color(0xFFFF6B35), // orange
      const Color(0xFFE91E63), // pink
      const Color(0xFF4CAF50), // green
      const Color(0xFFFF9800), // amber
      const Color(0xFF9C27B0), // deep purple
    ];
    return colors[hash % colors.length];
  }
}
