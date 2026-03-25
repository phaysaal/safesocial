import 'dart:io';

import 'package:flutter/material.dart';

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

    // Show image if we have a local file path
    if (imageRef != null && imageRef!.isNotEmpty) {
      final file = File(imageRef!);
      if (file.existsSync()) {
        return CircleAvatar(
          radius: size.radius,
          backgroundImage: FileImage(file),
        );
      }
    }

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

  Color _colorFromName(String name) {
    if (name.isEmpty) return const Color(0xFF7B2FBE);

    final hash = name.codeUnits.fold<int>(0, (prev, c) => prev + c);
    final colors = [
      const Color(0xFFC93D4E), // sunset rose
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
