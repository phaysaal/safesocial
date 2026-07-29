import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which relay this device talks to.
///
/// The relay holds no keys, no configuration and no user records, so pointing
/// at a different one is a supported operation rather than a hack: run the
/// worker in `relay/` yourself and put its host here. Being able to choose the
/// operator is most of what decentralisation means for this project — the relay
/// already cannot see who talks to whom or read content, but it can see that
/// *some* address is active and when.
class RelayConfig extends ChangeNotifier {
  static const _prefsKey = 'spheres_relay_host';

  static const String defaultHost = 'relay.spheres.dev';
  static const String fallbackHost = 'spheres-relay.phaysaal.workers.dev';

  /// Read directly by the transport services, which are not widgets and cannot
  /// watch a provider. Kept in sync by [load] and [setHost].
  static String primaryHost = defaultHost;

  String get host => primaryHost;
  bool get isCustom => primaryHost != defaultHost;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null && stored.isNotEmpty) primaryHost = stored;
    notifyListeners();
  }

  /// Returns an error message, or null on success.
  Future<String?> setHost(String value) async {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) return 'Enter a hostname';

    // A bare hostname only — the scheme is always https/wss, so a pasted URL
    // would otherwise produce silently broken requests.
    if (trimmed.contains('://') || trimmed.contains('/')) {
      return 'Enter just the hostname, without https:// or a path';
    }
    if (!RegExp(r'^[a-z0-9.-]+\.[a-z]{2,}$').hasMatch(trimmed)) {
      return 'That does not look like a hostname';
    }

    primaryHost = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, trimmed);
    notifyListeners();
    return null;
  }

  Future<void> resetToDefault() async {
    primaryHost = defaultHost;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }
}
