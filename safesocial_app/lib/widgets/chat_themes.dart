import 'package:flutter/material.dart';

/// Named looks for a chat, chosen per conversation and kept on this device.
class ChatThemes {
  ChatThemes._();

  static const List<(String id, String label)> all = [
    ('default', 'Spheres'),
    ('ocean', 'Ocean'),
    ('sunset', 'Sunset'),
    ('forest', 'Forest'),
    ('plum', 'Plum'),
    ('mono', 'Monochrome'),
  ];

  static String labelFor(String id) =>
      all.firstWhere((t) => t.$1 == id, orElse: () => all.first).$2;

  /// Our own bubbles, or null for the app's colour scheme.
  static Color? mine(String id) => switch (id) {
        'ocean' => const Color(0xFF1565C0),
        'sunset' => const Color(0xFFE65100),
        'forest' => const Color(0xFF2E7D32),
        'plum' => const Color(0xFF6A1B9A),
        'mono' => const Color(0xFF37474F),
        _ => null,
      };

  /// Their bubbles, or null for the default teal.
  static Color? theirs(String id, {required bool dark}) => switch (id) {
        'ocean' => dark ? const Color(0xFF0D47A1) : const Color(0xFF42A5F5),
        'sunset' => dark ? const Color(0xFFBF360C) : const Color(0xFFFF8A65),
        'forest' => dark ? const Color(0xFF1B5E20) : const Color(0xFF66BB6A),
        'plum' => dark ? const Color(0xFF4A148C) : const Color(0xFFAB47BC),
        'mono' => dark ? const Color(0xFF263238) : const Color(0xFF78909C),
        _ => null,
      };

  /// A wash behind the whole conversation, or null.
  static Color? wash(String id, {required bool dark}) {
    final m = mine(id);
    if (m == null) return null;
    return m.withValues(alpha: dark ? 0.12 : 0.06);
  }
}
