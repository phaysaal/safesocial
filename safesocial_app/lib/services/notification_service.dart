import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log_service.dart';
import 'inbound_events.dart';

/// Where notifications are actually shown. Abstract so the decision logic can
/// be tested without the platform plugin.
abstract class NotificationSink {
  /// Show [title]/[body] at [at], opening [route] when tapped. Replaces any
  /// earlier schedule with the same [id].
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String route,
  });

  Future<void> cancelScheduled(int id);

  Future<void> initialize({required void Function(String route) onTap});
  Future<bool> requestPermission();
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String thread,
    required String route,
    required bool highPriority,
  });
  Future<void> cancelThread(String thread);
}

/// Whether the UI is on screen. Set by the root widget's lifecycle observer;
/// false in a push wake, which has no UI at all.
class AppLifecycle {
  AppLifecycle._();
  static bool foreground = false;
}

/// Turns inbound events into local notifications, under the user's rules.
///
/// Every notification is built on the device from content that was decrypted
/// here. Nothing passes through a push provider: a wake carries no payload,
/// the app syncs, and then this decides what to show.
class NotificationService extends ChangeNotifier {
  static const _enabledKey = 'spheres_notifications_enabled';
  static const _previewKey = 'spheres_notifications_preview';
  static const _kindsKey = 'spheres_notifications_kinds';
  static const _askedKey = 'spheres_notifications_asked';

  final NotificationSink _sink;
  StreamSubscription<InboundEvent>? _subscription;

  bool _enabled = true;
  bool _preview = true;
  Set<InboundKind> _kinds = InboundKind.values.toSet();

  /// Ids already notified, so a message fetched twice shows once.
  final Set<String> _seen = {};

  /// Where a tapped notification should take the user. Set by the app shell.
  void Function(String route)? onOpen;

  NotificationService({NotificationSink? sink})
      : _sink = sink ?? LocalNotificationSink();

  bool get enabled => _enabled;
  bool get preview => _preview;
  bool allows(InboundKind kind) => _kinds.contains(kind);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    _preview = prefs.getBool(_previewKey) ?? true;
    _asked = prefs.getBool(_askedKey) ?? false;
    final kinds = prefs.getStringList(_kindsKey);
    if (kinds != null) {
      _kinds = kinds
          .map((n) => InboundKind.values.where((k) => k.name == n))
          .expand((k) => k)
          .toSet();
    }
    notifyListeners();
  }

  /// Start showing notifications for inbound events.
  Future<void> start() async {
    await _sink.initialize(onTap: (route) => onOpen?.call(route));
    _subscription ??= InboundEvents.stream.listen(_onEvent);
  }

  Future<bool> requestPermission() => _sink.requestPermission();

  bool _asked = false;

  /// Whether the system has been asked for permission on this install.
  bool get permissionAsked => _asked;

  /// Ask the system once, the first time an identity exists. Android 13 and
  /// later show nothing without this, and until it was added the only place
  /// that asked was a toggle in Settings that nobody had reason to open.
  /// Returns what the system answered, or null when the question had already
  /// been put.
  Future<bool?> ensurePermissionAsked() async {
    if (_asked) return null;
    _asked = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_askedKey, true);
    try {
      return await _sink.requestPermission();
    } catch (e) {
      DebugLogService().warn('Notify', 'Could not ask for permission: $e');
      return false;
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    (await SharedPreferences.getInstance()).setBool(_enabledKey, value);
    notifyListeners();
  }

  Future<void> setPreview(bool value) async {
    _preview = value;
    (await SharedPreferences.getInstance()).setBool(_previewKey, value);
    notifyListeners();
  }

  Future<void> setAllowed(InboundKind kind, bool allowed) async {
    if (allowed) {
      _kinds.add(kind);
    } else {
      _kinds.remove(kind);
    }
    (await SharedPreferences.getInstance())
        .setStringList(_kindsKey, _kinds.map((k) => k.name).toList());
    notifyListeners();
  }

  /// Decide, then show. Visible for tests.
  @visibleForTesting
  Future<bool> handle(InboundEvent event) => _onEvent(event);

  /// Whether a contact is muted, snoozed or on a break. Set by the app.
  bool Function(String identityKey)? isQuiet;

  /// A reminder the device shows by itself at [at], e.g. before an event.
  Future<void> scheduleReminder({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String route,
  }) async {
    if (!_enabled) return;
    try {
      await _sink.schedule(id: id, at: at, title: title, body: body, route: route);
    } catch (e) {
      DebugLogService().error('Notify', 'Could not schedule a reminder: $e');
    }
  }

  Future<void> cancelReminder(int id) async {
    try {
      await _sink.cancelScheduled(id);
    } catch (_) {}
  }

  Future<bool> _onEvent(InboundEvent event) async {
    if (!_enabled) return false;
    if (!_kinds.contains(event.kind)) return false;
    // A quiet contact's words stay quiet; a call still rings, because a
    // missed call is a different kind of harm from a missed post.
    final from = event.from;
    if (from != null && event.kind != InboundKind.call && (isQuiet?.call(from) ?? false)) {
      return false;
    }
    // Calls ring regardless of whether the app is on screen; everything else
    // is already visible when it is.
    if (AppLifecycle.foreground && event.kind != InboundKind.call) return false;
    if (!_seen.add(event.id)) return false;
    if (_seen.length > 2000) _seen.remove(_seen.first);

    try {
      await _sink.show(
        id: event.id.hashCode,
        title: event.title,
        body: _preview ? event.body : _generic(event.kind),
        thread: event.thread,
        route: event.route,
        highPriority: event.kind == InboundKind.call,
      );
      return true;
    } catch (e) {
      DebugLogService().error('Notify', 'Could not show a notification: $e');
      return false;
    }
  }

  static String _generic(InboundKind kind) {
    switch (kind) {
      case InboundKind.chat:
      case InboundKind.sphereChat:
        return 'New message';
      case InboundKind.post:
        return 'New post';
      case InboundKind.comment:
        return 'New comment';
      case InboundKind.reaction:
        return 'New reaction';
      case InboundKind.contactRequest:
        return 'Wants to connect';
      case InboundKind.call:
        return 'Incoming call';
      case InboundKind.security:
        return 'Security notice';
    }
  }

  /// A thread was opened; its notifications are stale.
  Future<void> clearThread(String thread) => _sink.cancelThread(thread);

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// `flutter_local_notifications`, with one channel per kind of thing.
class LocalNotificationSink implements NotificationSink {
  final _plugin = FlutterLocalNotificationsPlugin();
  final Map<String, List<int>> _byThread = {};
  bool _initialized = false;

  static const _messages = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'Direct and sphere messages',
    importance: Importance.high,
  );
  static const _activity = AndroidNotificationChannel(
    'activity',
    'Posts, comments and requests',
    description: 'Activity in your spheres',
    importance: Importance.defaultImportance,
  );
  static const _calls = AndroidNotificationChannel(
    'calls',
    'Calls',
    description: 'Incoming calls',
    importance: Importance.max,
  );

  @override
  Future<void> initialize({required void Function(String route) onTap}) async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (response) {
        final route = response.payload;
        if (route != null && route.isNotEmpty) onTap(route);
      },
    );
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      for (final channel in [_messages, _activity, _calls]) {
        await androidPlugin.createNotificationChannel(channel);
      }
    }
    _initialized = true;
  }

  @override
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String route,
  }) async {
    // The instant is what matters, so it is scheduled in UTC; no need to
    // know the device's zone name.
    tz.initializeTimeZones();
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(_activity.id, _activity.name,
            channelDescription: _activity.description,
            importance: Importance.high,
            priority: Priority.high),
        iOS: const DarwinNotificationDetails(),
      ),
      // Inexact: no alarm permission, and a minute either way is fine for a
      // reminder.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: route,
    );
  }

  @override
  Future<void> cancelScheduled(int id) => _plugin.cancel(id: id);

  @override
  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return true;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String thread,
    required String route,
    required bool highPriority,
  }) async {
    final channel = highPriority
        ? _calls
        : (thread.startsWith('chat:') || thread.startsWith('sphere:')
            ? _messages
            : _activity);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: channel.importance,
        priority: highPriority ? Priority.max : Priority.high,
        groupKey: thread,
        category: highPriority ? AndroidNotificationCategory.call : null,
        fullScreenIntent: highPriority,
      ),
      iOS: DarwinNotificationDetails(
        threadIdentifier: thread,
        interruptionLevel: highPriority
            ? InterruptionLevel.timeSensitive
            : InterruptionLevel.active,
      ),
    );
    await _plugin.show(id: id, title: title, body: body, notificationDetails: details, payload: route);
    _byThread.putIfAbsent(thread, () => []).add(id);
  }

  @override
  Future<void> cancelThread(String thread) async {
    final ids = _byThread.remove(thread) ?? const [];
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
  }
}
