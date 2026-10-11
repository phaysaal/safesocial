import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/event_time.dart';
import '../../services/event_reminders.dart';
import '../../services/feed_service.dart';
import '../../services/library_service.dart';
import '../../services/sphere_service.dart';

/// Every event still to come across all spheres, soonest first.
class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<FeedService>();
    final library = context.watch<LibraryService>();
    final spheres = context.watch<SphereService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final events = feed.upcomingEvents;

    return Scaffold(
      appBar: AppBar(title: const Text('Upcoming events')),
      body: events.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text('Nothing coming up. An event is a post with a time; make one from the composer.',
                    textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              ),
            )
          : ListView.separated(
              itemCount: events.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final p = events[i];
                final payload = p.payload ?? const {};
                final start = EventReminders.nextStart(p);
                final recurrence = payload['recurrence'] as String? ?? 'none';
                final reminders = library.eventReminders(p.id);
                final sphereName = p.sphereIds.map(spheres.sphere).whereType<Object>().map((s) => (s as dynamic).name as String).join(', ');
                return ListTile(
                  leading: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(start == null ? '' : '${start.day}',
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: cs.primary)),
                      Text(start == null ? '' : _month(start.month), style: theme.textTheme.labelSmall),
                    ],
                  ),
                  title: Text(payload['title'] as String? ?? 'Event'),
                  subtitle: Text([
                    if (start != null) '${_time(start)}',
                    if ((payload['place'] as String? ?? '').isNotEmpty) payload['place'] as String,
                    if (recurrence != 'none') EventTime.label(recurrence),
                    if (sphereName.isNotEmpty) sphereName,
                  ].join(' · ')),
                  trailing: reminders.isEmpty
                      ? null
                      : Icon(Icons.notifications_active_outlined, color: cs.primary, size: 20),
                  onTap: () => context.push('/post/${p.id}'),
                );
              },
            ),
    );
  }

  static String _month(int m) =>
      const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1];

  static String _time(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
