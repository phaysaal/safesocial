import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which STUN and TURN servers calls use.
///
/// This matters for privacy, and the default is not good. A STUN server learns
/// your public IP; a TURN server, when direct connection fails, relays the
/// whole call and therefore sees both parties' IPs and the timing and volume of
/// the media — the content stays protected by SRTP, but the metadata does not.
///
/// The defaults are Google's public STUN and the free shared-credential
/// `openrelay.metered.ca` TURN, which means an unaffiliated third party is in
/// that position by default. Replacing them with your own coturn instance is
/// the recommended setup for anything sensitive; this makes that possible
/// without rebuilding the app.
///
/// Turning TURN off entirely is also offered: calls then only connect when a
/// direct path exists, which fails behind some NATs but guarantees no third
/// party carries the media.
class CallConfig extends ChangeNotifier {
  static const _serversKey = 'spheres_ice_servers';
  static const _turnEnabledKey = 'spheres_turn_enabled';

  static const List<Map<String, String>> defaultStun = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  static const List<Map<String, String>> defaultTurn = [
    {
      'urls': 'turn:openrelay.metered.ca:80',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  /// Read by CallService, which is not a widget and cannot watch a provider.
  static List<Map<String, String>> active = [...defaultStun, ...defaultTurn];

  List<Map<String, String>>? _custom;
  bool _turnEnabled = true;

  bool get turnEnabled => _turnEnabled;
  bool get isCustom => _custom != null;

  /// A human-readable summary for the settings screen.
  String get summary {
    if (_custom != null) return 'Custom (${_custom!.length} server(s))';
    return _turnEnabled
        ? 'Default STUN + public TURN relay'
        : 'Default STUN only — no relay fallback';
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _turnEnabled = prefs.getBool(_turnEnabledKey) ?? true;

    final raw = prefs.getString(_serversKey);
    if (raw != null && raw.isNotEmpty) {
      final parsed = _parse(raw);
      if (parsed != null) _custom = parsed;
    }
    _apply();
    notifyListeners();
  }

  /// Accepts one server per line: `url[,username,credential]`.
  /// Returns an error message, or null on success.
  Future<String?> setCustom(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'Enter at least one server, or reset to default';

    final parsed = _parse(trimmed);
    if (parsed == null || parsed.isEmpty) {
      return 'Each line must be stun:… or turn:… optionally followed by '
          ',username,credential';
    }

    _custom = parsed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serversKey, trimmed);
    _apply();
    notifyListeners();
    return null;
  }

  Future<void> setTurnEnabled(bool enabled) async {
    _turnEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_turnEnabledKey, enabled);
    _apply();
    notifyListeners();
  }

  Future<void> resetToDefault() async {
    _custom = null;
    _turnEnabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serversKey);
    await prefs.remove(_turnEnabledKey);
    _apply();
    notifyListeners();
  }

  void _apply() {
    if (_custom != null) {
      active = _custom!;
      return;
    }
    active = [...defaultStun, if (_turnEnabled) ...defaultTurn];
  }

  static List<Map<String, String>>? _parse(String text) {
    final servers = <Map<String, String>>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(',').map((p) => p.trim()).toList();
      final url = parts.first;
      if (!url.startsWith('stun:') && !url.startsWith('turn:')) return null;

      if (parts.length == 1) {
        servers.add({'urls': url});
      } else if (parts.length == 3) {
        servers.add({
          'urls': url,
          'username': parts[1],
          'credential': parts[2],
        });
      } else {
        return null;
      }
    }
    return servers;
  }
}
