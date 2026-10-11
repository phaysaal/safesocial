import '../models/event_time.dart';
import '../models/post.dart';
import 'feed_service.dart';
import 'library_service.dart';
import 'notification_service.dart';

/// Reminders before events, kept on this device and shown by it.
///
/// The choice per event lives in [LibraryService]; the device's notification
/// scheduler holds the actual alarms, which do not survive a reinstall or
/// some reboots, so [resync] runs at every start and schedules whatever is
/// still ahead.
class EventReminders {
  EventReminders._();

  /// The offsets a user can pick, in minutes before the start.
  static const choices = [15, 60, 1440, 10080];

  static String labelFor(int minutes) => switch (minutes) {
        15 => '15 minutes before',
        60 => 'An hour before',
        1440 => 'A day before',
        10080 => 'A week before',
        _ => '$minutes minutes before',
      };

  static int notificationId(String postId, int minutes) =>
      'reminder:$postId:$minutes'.hashCode & 0x7fffffff;

  /// When the event (or its next occurrence) starts, or null when it is over.
  static DateTime? nextStart(Post post, {DateTime? now}) {
    final starts = DateTime.tryParse(post.payload?['starts_at'] as String? ?? '');
    if (starts == null) return null;
    final ends = DateTime.tryParse(post.payload?['ends_at'] as String? ?? '');
    final recurrence = post.payload?['recurrence'] as String? ?? 'none';
    final at = now ?? DateTime.now();
    if (EventTime.isPast(starts: starts, ends: ends, recurrence: recurrence, now: at)) return null;
    return EventTime.occurrence(starts: starts, ends: ends, recurrence: recurrence, now: at).starts;
  }

  /// Set the reminders for one event: everything not chosen is cancelled,
  /// everything chosen and still ahead is scheduled.
  static Future<void> set({
    required Post post,
    required List<int> minutesBefore,
    required LibraryService library,
    required NotificationService notifications,
  }) async {
    await library.setEventReminders(post.id, minutesBefore);
    await _schedule(post, minutesBefore, notifications);
  }

  static Future<void> _schedule(
      Post post, List<int> minutesBefore, NotificationService notifications) async {
    final start = nextStart(post);
    final title = post.payload?['title'] as String? ?? 'Event';
    for (final m in choices) {
      final id = notificationId(post.id, m);
      final at = start?.subtract(Duration(minutes: m));
      if (!minutesBefore.contains(m) || at == null || !at.isAfter(DateTime.now())) {
        await notifications.cancelReminder(id);
        continue;
      }
      await notifications.scheduleReminder(
        id: id,
        at: at,
        title: title,
        body: 'Starts ${labelFor(m).toLowerCase().replaceFirst(' before', ' from now')}',
        route: '/post/${post.id}',
      );
    }
  }

  /// Re-schedule every reminder for every event still to come.
  static Future<void> resync({
    required FeedService feed,
    required LibraryService library,
    required NotificationService notifications,
  }) async {
    final byId = {for (final p in feed.posts) p.id: p};
    for (final e in library.allEventReminders.entries) {
      final post = byId[e.key];
      if (post == null || !post.isEvent) continue;
      await _schedule(post, e.value, notifications);
    }
  }
}
