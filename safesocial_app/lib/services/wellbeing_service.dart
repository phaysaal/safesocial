import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'inbound_events.dart';
import 'secure_store.dart';

/// Time on the app, breaks, quiet hours, a daily reminder and a pause that
/// keeps the keys. Everything here is local; nobody is told how long you
/// were here.
///
/// A break: after [breakEvery] of continuous use the screen dims for
/// [breakLength] and a countdown shows. Leaving the app for a few minutes
/// counts as a break of its own and resets the clock.
class WellbeingService extends ChangeNotifier {
  static const _key = 'spheres_wellbeing_v1';
  static const breakEvery = Duration(minutes: 20);
  static const breakLength = Duration(seconds: 20);

  /// Away for at least this long resets the continuous-use clock.
  static const awayResets = Duration(minutes: 5);

  bool _breakReminders = true;
  int _dailyLimitMinutes = 0;
  int? _quietStart;
  int? _quietEnd;
  bool _paused = false;
  final Map<String, int> _usage = {};

  int _sessionSeconds = 0;
  bool _breakActive = false;
  int _breakRemaining = 0;
  bool _dailyReminded = false;
  bool _foreground = false;
  DateTime? _leftAt;
  Timer? _ticker;
  int _sinceSave = 0;

  /// Supplies "now"; tests set it.
  DateTime Function() clock = DateTime.now;

  /// Told when the pause changes, so the app can rest or wake the relay.
  Future<void> Function(bool paused)? onPauseChanged;

  bool get breakReminders => _breakReminders;
  int get dailyLimitMinutes => _dailyLimitMinutes;
  int? get quietStart => _quietStart;
  int? get quietEnd => _quietEnd;
  bool get paused => _paused;
  bool get breakActive => _breakActive;
  int get breakRemaining => _breakRemaining;
  int get sessionSeconds => _sessionSeconds;
  bool get dailyLimitReached =>
      _dailyLimitMinutes > 0 && minutesToday >= _dailyLimitMinutes;

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int secondsOn(DateTime day) => _usage[dayKey(day)] ?? 0;
  int get minutesToday => secondsOn(clock()) ~/ 60;

  /// The last seven days, oldest first, as (day, minutes).
  List<(DateTime, int)> get lastSevenDays {
    final today = clock();
    return [
      for (var i = 6; i >= 0; i--)
        () {
          final d = DateTime(today.year, today.month, today.day - i);
          return (d, secondsOn(d) ~/ 60);
        }(),
    ];
  }

  bool inQuietHours({DateTime? now}) {
    final s = _quietStart, e = _quietEnd;
    if (s == null || e == null || s == e) return false;
    final t = now ?? clock();
    final m = t.hour * 60 + t.minute;
    return s < e ? (m >= s && m < e) : (m >= s || m < e);
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void onForeground() {
    if (_foreground) return;
    _foreground = true;
    final left = _leftAt;
    if (left != null && clock().difference(left) >= awayResets) {
      _sessionSeconds = 0;
      _endBreak(reset: false);
    }
    _leftAt = null;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void onBackground() {
    if (!_foreground) return;
    _foreground = false;
    _leftAt = clock();
    _ticker?.cancel();
    _ticker = null;
    unawaited(_persist());
  }

  /// One second of use. Public so tests can advance time.
  void tick({int seconds = 1}) {
    if (_paused) return;
    final today = dayKey(clock());
    _usage[today] = (_usage[today] ?? 0) + seconds;
    _sinceSave += seconds;
    if (_breakActive) {
      _breakRemaining -= seconds;
      if (_breakRemaining <= 0) _endBreak(reset: true);
      notifyListeners();
    } else {
      _sessionSeconds += seconds;
      if (_breakReminders && _sessionSeconds >= breakEvery.inSeconds) {
        _breakActive = true;
        _breakRemaining = breakLength.inSeconds;
        notifyListeners();
      }
    }
    if (_dailyLimitMinutes > 0 && !_dailyReminded && minutesToday >= _dailyLimitMinutes) {
      _dailyReminded = true;
      InboundEvents.emit(InboundEvent(
        kind: InboundKind.security,
        id: 'daily:$today',
        title: 'Your daily reminder',
        body: 'You have been on Spheres for $minutesToday minutes today.',
        route: '/wellbeing',
        thread: 'wellbeing',
      ));
      notifyListeners();
    }
    if (_sinceSave >= 30) {
      _sinceSave = 0;
      unawaited(_persist());
    }
  }

  /// End the break early. The clock starts again from zero either way.
  void skipBreak() => _endBreak(reset: true);

  void _endBreak({required bool reset}) {
    _breakActive = false;
    _breakRemaining = 0;
    if (reset) _sessionSeconds = 0;
    notifyListeners();
  }

  // ── Settings ───────────────────────────────────────────────────────────────

  Future<void> setBreakReminders(bool on) async {
    _breakReminders = on;
    if (!on) _endBreak(reset: true);
    await _persist();
    notifyListeners();
  }

  Future<void> setDailyLimit(int minutes) async {
    _dailyLimitMinutes = minutes.clamp(0, 24 * 60);
    _dailyReminded = false;
    await _persist();
    notifyListeners();
  }

  Future<void> setQuietHours(int? startMinute, int? endMinute) async {
    _quietStart = startMinute;
    _quietEnd = endMinute;
    await _persist();
    notifyListeners();
  }

  /// Pause: the relay socket rests, nothing is sent or fetched, the keys and
  /// every store stay exactly as they are. Resume brings it all back.
  Future<void> setPaused(bool on) async {
    if (_paused == on) return;
    _paused = on;
    await _persist();
    notifyListeners();
    await onPauseChanged?.call(on);
  }

  Future<void> _persist() => SecureStore.instance.setString(
        _key,
        jsonEncode({
          'breaks': _breakReminders,
          'daily': _dailyLimitMinutes,
          'quietStart': _quietStart,
          'quietEnd': _quietEnd,
          'paused': _paused,
          'usage': _usage,
        }),
      );

  Future<void> load() async {
    final raw = await SecureStore.instance.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _breakReminders = j['breaks'] != false;
      _dailyLimitMinutes = j['daily'] is int ? j['daily'] as int : 0;
      _quietStart = j['quietStart'] is int ? j['quietStart'] as int : null;
      _quietEnd = j['quietEnd'] is int ? j['quietEnd'] as int : null;
      _paused = j['paused'] == true;
      _usage.clear();
      (j['usage'] as Map?)?.forEach((k, v) {
        if (v is int) _usage['$k'] = v;
      });
      // Keep a month; the dashboard shows a week.
      final cutoff = dayKey(clock().subtract(const Duration(days: 31)));
      _usage.removeWhere((k, _) => k.compareTo(cutoff) < 0);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
