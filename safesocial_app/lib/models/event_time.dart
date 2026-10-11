/// Time arithmetic for events: when a recurring event happens next, whether
/// an event is over, and the iCalendar text for one. Pure, so the card, the
/// reminders and the export all agree.
class EventTime {
  EventTime._();

  static const recurrences = ['none', 'daily', 'weekly', 'monthly', 'yearly'];

  static String label(String recurrence) => switch (recurrence) {
        'daily' => 'Repeats every day',
        'weekly' => 'Repeats every week',
        'monthly' => 'Repeats every month',
        'yearly' => 'Repeats every year',
        _ => '',
      };

  static DateTime _step(DateTime d, String recurrence) => switch (recurrence) {
        'daily' => d.add(const Duration(days: 1)),
        'weekly' => d.add(const Duration(days: 7)),
        'monthly' => DateTime(d.year, d.month + 1, d.day, d.hour, d.minute),
        'yearly' => DateTime(d.year + 1, d.month, d.day, d.hour, d.minute),
        _ => d,
      };

  /// The occurrence that matters at [now]: the one under way, or the next
  /// one. A one-off event is its own only occurrence, past or not. The end
  /// keeps its distance from the start.
  static ({DateTime starts, DateTime? ends}) occurrence({
    required DateTime starts,
    DateTime? ends,
    String recurrence = 'none',
    required DateTime now,
  }) {
    if (!recurrences.contains(recurrence) || recurrence == 'none') {
      return (starts: starts, ends: ends);
    }
    final length = ends == null ? Duration.zero : ends.difference(starts);
    var s = starts;
    // A bound against a recurrence that never catches up (a daily event
    // created decades ago still terminates).
    for (var i = 0; i < 20000; i++) {
      final e = s.add(length);
      if (e.isAfter(now) || (length == Duration.zero && !s.isBefore(now))) break;
      final next = _step(s, recurrence);
      if (!next.isAfter(s)) break;
      s = next;
    }
    return (starts: s, ends: ends == null ? null : s.add(length));
  }

  /// Over, with nothing more to come.
  static bool isPast({
    required DateTime starts,
    DateTime? ends,
    String recurrence = 'none',
    required DateTime now,
  }) {
    if (recurrences.contains(recurrence) && recurrence != 'none') return false;
    final end = ends ?? starts;
    return end.isBefore(now);
  }

  static String _utc(DateTime d) {
    final u = d.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}T${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
  }

  static String _escape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll(';', '\\;')
      .replaceAll(',', '\\,')
      .replaceAll('\n', '\\n');

  /// One VEVENT in a VCALENDAR, as any calendar app imports it.
  static String ics({
    required String uid,
    required String title,
    required DateTime starts,
    DateTime? ends,
    String place = '',
    String description = '',
    String recurrence = 'none',
    String url = '',
  }) {
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Spheres//EN',
      'BEGIN:VEVENT',
      'UID:$uid',
      'DTSTAMP:${_utc(DateTime.now())}',
      'DTSTART:${_utc(starts)}',
      if (ends != null) 'DTEND:${_utc(ends)}',
      'SUMMARY:${_escape(title)}',
      if (place.isNotEmpty) 'LOCATION:${_escape(place)}',
      if (description.isNotEmpty) 'DESCRIPTION:${_escape(description)}',
      if (url.isNotEmpty) 'URL:${_escape(url)}',
      if (recurrence != 'none' && recurrences.contains(recurrence))
        'RRULE:FREQ=${recurrence.toUpperCase()}',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return '${lines.join('\r\n')}\r\n';
  }
}
