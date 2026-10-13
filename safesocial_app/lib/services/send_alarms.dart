import 'dart:async';

import 'package:flutter/services.dart';

import 'chat_service.dart';
import 'debug_log_service.dart';
import 'feed_service.dart';

/// Wakes the app at the minute a scheduled message or post is due, so it
/// goes on time and not when the app next opens.
///
/// One alarm, for the earliest pending time across chat and feed, re-set
/// whenever the schedule changes and at every start (alarms do not survive a
/// reboot). On Android it is an exact alarm through `spheres/alarms` in
/// `MainActivity.kt`; when the alarm fires and no engine is alive,
/// `AlarmReceiver` starts a headless one with `--scheduled-bg`, which runs
/// the same sweeps the foreground app runs every thirty seconds. Android 12+
/// lets the person refuse exact alarms, in which case the platform answers
/// that the alarm it set is inexact and the UI says the send may be late.
/// Where there is no platform code (tests, other platforms) nothing is set
/// and [exact] is false, so nothing claims a wake it will not get.
class SendAlarms {
  SendAlarms._();

  static const channel = MethodChannel('spheres/alarms');

  /// Runs the due sweeps; set by the wiring, called when the platform says
  /// an alarm fired while the app was alive.
  static Future<void> Function()? onDue;

  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'due') await onDue?.call();
    });
  }

  /// The soonest of every pending time, or null when nothing waits.
  static DateTime? earliest(Iterable<DateTime> times) {
    DateTime? best;
    for (final t in times) {
      if (best == null || t.isBefore(best)) best = t;
    }
    return best;
  }

  /// Whether the platform will wake us exactly on time.
  static Future<bool> exactAllowed() async {
    _listen();
    try {
      return await channel.invokeMethod<bool>('exact') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Open the system page where exact alarms are allowed (Android 12+).
  static Future<void> openSettings() async {
    try {
      await channel.invokeMethod<void>('settings');
    } catch (_) {}
  }

  /// Set the one alarm to the earliest pending time, or clear it. Returns
  /// whether an exact alarm was set.
  static Future<bool> resync(ChatService chat, FeedService feed) async {
    _listen();
    final times = <DateTime>[
      for (final s in chat.allScheduled) s.at,
      for (final d in feed.drafts)
        if (DateTime.tryParse(d['scheduledFor'] as String? ?? '') case final at?) at,
    ];
    final at = earliest(times);
    try {
      if (at == null) {
        await channel.invokeMethod<void>('cancel');
        return false;
      }
      final exact = await channel.invokeMethod<bool>('set', {'at': at.millisecondsSinceEpoch}) == true;
      DebugLogService().info('Alarms', '${exact ? 'Exact' : 'Inexact'} wake set for $at');
      return exact;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      DebugLogService().warn('Alarms', 'Could not set the wake: ${e.message}');
      return false;
    }
  }

  /// Tell the platform the headless run is over, so it can let the process go.
  static Future<void> done() async {
    try {
      await channel.invokeMethod<void>('done');
    } catch (_) {}
  }
}
