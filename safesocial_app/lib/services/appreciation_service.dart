import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'inbound_events.dart';
import 'secure_store.dart';

/// One reaction waiting for the day's delivery.
class PendingAppreciation {
  final String postId;
  final String reactor;
  final String emoji;
  final bool onComment;
  final DateTime at;

  const PendingAppreciation({
    required this.postId,
    required this.reactor,
    required this.emoji,
    required this.onComment,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'post': postId,
        'by': reactor,
        'emoji': emoji,
        'comment': onComment,
        'at': at.toIso8601String(),
      };

  static PendingAppreciation? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final post = raw['post'], by = raw['by'], emoji = raw['emoji'];
    if (post is! String || by is! String || emoji is! String) return null;
    return PendingAppreciation(
      postId: post,
      reactor: by,
      emoji: emoji,
      onComment: raw['comment'] == true,
      at: DateTime.tryParse(raw['at'] as String? ?? '') ?? DateTime(2026),
    );
  }
}

/// Appreciation that completes instead of dripping.
///
/// A reaction to our post used to notify the moment it arrived, one at a
/// time, at whatever hour someone else chose: the slot machine. By default
/// they are now held and delivered once a day at an hour the person picks,
/// one line per post with every name, so the warmth arrives whole and the
/// loop closes. "As it happens" remains a choice. The plan's §12.6 says why.
class AppreciationService extends ChangeNotifier {
  static const _modeKey = 'appreciation_mode';
  static const _hourKey = 'appreciation_hour';
  static const _minuteKey = 'appreciation_minute';
  static const _pendingKey = 'spheres_appreciation_pending_v1';
  static const _deliveredKey = 'appreciation_delivered_day';

  bool _daily = true;
  int _hour = 19;
  int _minute = 0;
  String? _deliveredDay;
  final List<PendingAppreciation> _pending = [];
  Timer? _ticker;

  /// Supplies "now"; tests set it.
  DateTime Function() clock = DateTime.now;

  /// Names people for the lines; set by the app.
  String Function(String identityKey)? resolveName;

  /// A line about the post, for the body; set by the app.
  String Function(String postId)? describePost;

  bool get daily => _daily;
  int get hour => _hour;
  int get minute => _minute;
  int get pendingCount => _pending.length;

  String get summary => _daily
      ? 'Once a day at ${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}'
      : 'As it happens';

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _daily = prefs.getBool(_modeKey) ?? true;
    _hour = (prefs.getInt(_hourKey) ?? 19).clamp(0, 23);
    _minute = (prefs.getInt(_minuteKey) ?? 0).clamp(0, 59);
    _deliveredDay = prefs.getString(_deliveredKey);
    final raw = await SecureStore.instance.getString(_pendingKey);
    if (raw != null) {
      try {
        _pending
          ..clear()
          ..addAll((jsonDecode(raw) as List).map(PendingAppreciation.tryParse).whereType<PendingAppreciation>());
      } catch (_) {}
    }
  }

  /// Check the clock every minute while the app runs.
  void start() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => tick());
  }

  Future<void> setDaily(bool on) async {
    _daily = on;
    (await SharedPreferences.getInstance()).setBool(_modeKey, on);
    notifyListeners();
    // Switching to "as it happens" with a day's worth held: deliver it now
    // rather than lose it or hold it for a time that no longer applies.
    if (!on && _pending.isNotEmpty) await deliver();
  }

  Future<void> setTime(int hour, int minute) async {
    _hour = hour.clamp(0, 23);
    _minute = minute.clamp(0, 59);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_hourKey, _hour);
    await prefs.setInt(_minuteKey, _minute);
    notifyListeners();
  }

  /// A reaction to our post or comment arrived. True when it is held for the
  /// day's delivery; false when the caller should notify as it happens.
  bool record({required String postId, required String reactor, required String emoji, required bool onComment}) {
    if (!_daily) return false;
    _pending.removeWhere((p) => p.postId == postId && p.reactor == reactor && p.onComment == onComment);
    _pending.add(PendingAppreciation(postId: postId, reactor: reactor, emoji: emoji, onComment: onComment, at: clock()));
    unawaited(_persist());
    notifyListeners();
    return true;
  }

  /// Someone took their reaction back before the delivery: nothing to say.
  void forget({required String postId, required String reactor}) {
    final before = _pending.length;
    _pending.removeWhere((p) => p.postId == postId && p.reactor == reactor);
    if (_pending.length != before) {
      unawaited(_persist());
      notifyListeners();
    }
  }

  /// Whether the day's hour has come and today's delivery is still owed.
  bool get due {
    if (!_daily) return false;
    final now = clock();
    if (_deliveredDay == dayKey(now)) return false;
    final minutes = now.hour * 60 + now.minute;
    return minutes >= _hour * 60 + _minute;
  }

  /// Called every minute while the app runs, and at every start.
  Future<void> tick() async {
    if (!due) return;
    await deliver();
  }

  /// One line per post, every name on it, delivered together. Pure in what
  /// it says: [lines] is the shape, [deliver] the act.
  static List<(String postId, String body)> lines(
    Iterable<PendingAppreciation> pending, {
    required String Function(String) nameOf,
    required String Function(String) postOf,
  }) {
    final byPost = <String, List<PendingAppreciation>>{};
    for (final p in pending) {
      byPost.putIfAbsent(p.postId, () => []).add(p);
    }
    final out = <(String, String)>[];
    for (final e in byPost.entries) {
      final names = e.value.map((p) => nameOf(p.reactor)).toSet().toList()..sort();
      final who = switch (names.length) {
        1 => names.single,
        2 => '${names[0]} and ${names[1]}',
        _ => '${names.take(names.length - 1).join(', ')} and ${names.last}',
      };
      final emojis = e.value.map((p) => p.emoji).toSet().join(' ');
      final what = postOf(e.key);
      out.add((e.key, '$who appreciated $what $emojis'));
    }
    return out;
  }

  /// Deliver whatever is held, as one notification per post, and mark the
  /// day done. Nothing held: the day is marked all the same, so the hour is
  /// not asked again until tomorrow.
  Future<void> deliver() async {
    final now = clock();
    _deliveredDay = dayKey(now);
    (await SharedPreferences.getInstance()).setString(_deliveredKey, _deliveredDay!);
    if (_pending.isEmpty) return;
    final held = List.of(_pending);
    _pending.clear();
    await _persist();
    for (final (postId, body) in lines(
      held,
      nameOf: (k) => resolveName?.call(k) ?? 'Someone',
      postOf: (id) => describePost?.call(id) ?? 'your post',
    )) {
      InboundEvents.emit(InboundEvent(
        kind: InboundKind.reaction,
        id: 'appreciation:$postId:${dayKey(now)}',
        title: 'Appreciation today',
        body: body,
        route: '/post/$postId',
        thread: 'appreciation',
      ));
    }
    notifyListeners();
  }

  Future<void> _persist() => SecureStore.instance.setString(
      _pendingKey, jsonEncode(_pending.map((p) => p.toJson()).toList()));

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
