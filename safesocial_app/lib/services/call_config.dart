import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which STUN and TURN servers calls use.
///
/// This matters for privacy. A STUN server learns your public IP; a TURN
/// server, when direct connection fails, relays the whole call and therefore
/// sees both parties' IPs and the timing and volume of the media — the content
/// stays protected by SRTP, but the metadata does not.
///
/// The default is **servers run by whoever runs your relay**: the relay issues
/// short-lived TURN credentials (`/turn`) for its own coturn, so no credential
/// lives in the app and no unaffiliated third party is in the path. If the
/// relay has no TURN configured it says so, and calls fall back to public STUN
/// only, which is stated in Settings rather than papered over. The old default
/// — the free shared-credential `openrelay.metered.ca` — is gone.
///
/// Custom servers remain available, as does turning TURN off entirely: calls
/// then only connect when a direct path exists, which fails behind some NATs
/// but guarantees no third party carries the media.
class CallConfig extends ChangeNotifier {
  static const _serversKey = 'spheres_ice_servers';
  static const _turnEnabledKey = 'spheres_turn_enabled';
  static const _relayOnlyKey = 'spheres_call_relay_only';

  /// Used only when the relay offers no TURN of its own. A STUN lookup
  /// reveals your IP to Google; that is stated in Settings when it applies.
  static const List<Map<String, String>> fallbackStun = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  /// Snapshot read by code that is not a widget. Static mirrors of the
  /// instance state, kept in sync by every setter.
  static List<Map<String, String>>? _custom;
  static bool _turnEnabled = true;

  /// Every call goes through TURN, even when a direct path exists. This is
  /// how the TURN path gets exercised on purpose; it costs the operator
  /// bandwidth, so it is off unless someone switches it on.
  static bool _relayOnly = false;
  static bool get relayOnly => _relayOnly;

  /// Credentials the relay issued, and when they stop being trusted.
  static List<Map<String, String>>? _issued;
  static DateTime? _issuedUntil;

  /// Null until the relay has been asked; false after it answered that it has
  /// no TURN configured.
  static bool? relayOffersTurn;

  /// Replaceable clock, for tests.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  bool get turnEnabled => _turnEnabled;
  bool get relayOnlyEnabled => _relayOnly;
  bool get isCustom => _custom != null;

  /// The configuration for a new peer connection: the servers, and the
  /// transport policy that forces the relay path when asked to.
  static Map<String, dynamic> peerConnectionConfig(
      List<Map<String, String>> iceServers) {
    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      if (_relayOnly && _turnEnabled) 'iceTransportPolicy': 'relay',
    };
  }

  /// A human-readable summary for the settings screen.
  String get summary {
    final custom = _custom;
    if (custom != null) return 'Custom (${custom.length} server(s))';
    if (!_turnEnabled) return 'Direct connections only — no TURN relay';
    if (_relayOnly) return 'Every call relayed through TURN (test setting)';
    switch (relayOffersTurn) {
      case true:
        return 'STUN + TURN issued by your relay';
      case false:
        return 'Your relay offers no TURN — direct connections only, '
            'public STUN';
      case null:
        return 'STUN + TURN from your relay (not yet contacted)';
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _turnEnabled = prefs.getBool(_turnEnabledKey) ?? true;
    _relayOnly = prefs.getBool(_relayOnlyKey) ?? false;

    final raw = prefs.getString(_serversKey);
    if (raw != null && raw.isNotEmpty) {
      final parsed = _parse(raw);
      if (parsed != null) _custom = parsed;
    }
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
    notifyListeners();
    return null;
  }

  Future<void> setTurnEnabled(bool enabled) async {
    _turnEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_turnEnabledKey, enabled);
    notifyListeners();
  }

  Future<void> setRelayOnly(bool on) async {
    _relayOnly = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_relayOnlyKey, on);
    notifyListeners();
  }

  Future<void> resetToDefault() async {
    _custom = null;
    _turnEnabled = true;
    _relayOnly = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serversKey);
    await prefs.remove(_turnEnabledKey);
    await prefs.remove(_relayOnlyKey);
    notifyListeners();
  }

  /// The ICE servers for a call that is about to be set up.
  ///
  /// [fetchFromRelay] asks the relay for credentials; it returns the `/turn`
  /// body, or null when the relay could not be reached or has none. Issued
  /// credentials are cached for most of their lifetime so a reconnect inside
  /// one call does not need a second round trip.
  static Future<List<Map<String, String>>> resolve(
    Future<Map<String, dynamic>?> Function() fetchFromRelay,
  ) async {
    final custom = _custom;
    if (custom != null) return custom;

    final cached = _issued;
    final until = _issuedUntil;
    if (cached == null || until == null || now().isAfter(until)) {
      final body = await fetchFromRelay();
      final issued = _fromRelay(body);
      if (issued == null) {
        relayOffersTurn = false;
        _issued = null;
        _issuedUntil = null;
      } else {
        relayOffersTurn = true;
        _issued = issued;
        final ttl = (body!['ttl'] as num?)?.toInt() ?? 3600;
        _issuedUntil = now().add(Duration(seconds: (ttl * 0.8).round()));
      }
    }

    final issued = _issued;
    if (issued == null) return fallbackStun;
    if (!_turnEnabled) {
      return issued.where((s) => s['urls']!.startsWith('stun:')).toList();
    }
    return issued;
  }

  /// Turn a `/turn` response into ICE servers: every TURN URL with the issued
  /// credential, plus a STUN entry on the same host so address discovery also
  /// stays with the relay operator.
  static List<Map<String, String>>? _fromRelay(Map<String, dynamic>? body) {
    if (body == null || body['configured'] != true) return null;
    final urls = (body['urls'] as List?)?.whereType<String>().toList() ?? [];
    final username = body['username'];
    final credential = body['credential'];
    if (urls.isEmpty || username is! String || credential is! String) {
      return null;
    }

    final servers = <Map<String, String>>[];
    final stunHosts = <String>{};
    for (final url in urls) {
      if (url.startsWith('stun:')) {
        servers.add({'urls': url});
        continue;
      }
      if (!url.startsWith('turn:') && !url.startsWith('turns:')) continue;
      servers.add({'urls': url, 'username': username, 'credential': credential});
      // turn:host:port?transport=udp → stun:host:port
      final hostPort = url.substring(url.indexOf(':') + 1).split('?').first;
      if (url.startsWith('turn:') && stunHosts.add(hostPort)) {
        servers.insert(0, {'urls': 'stun:$hostPort'});
      }
    }
    return servers.isEmpty ? null : servers;
  }

  /// Forget issued credentials, e.g. after the relay host changed.
  static void forgetIssued() {
    _issued = null;
    _issuedUntil = null;
    relayOffersTurn = null;
  }

  static List<Map<String, String>>? _parse(String text) {
    final servers = <Map<String, String>>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(',').map((p) => p.trim()).toList();
      final url = parts.first;
      if (!url.startsWith('stun:') &&
          !url.startsWith('turn:') &&
          !url.startsWith('turns:')) {
        return null;
      }

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
