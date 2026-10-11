import 'package:flutter/material.dart';

import '../models/post.dart';
import 'media_thumb.dart';
import '../models/event_time.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/chat_service.dart';

/// An event inside a post: when, where, who is hosting, who is coming,
/// and the pictures people added. Everything that needs a service comes in
/// as a callback, so the card stays a picture of the post.
class EventCard extends StatelessWidget {
  final Post post;
  final String? myKey;
  final String Function(String key) nameFor;
  final void Function(String status)? onRsvp;
  final bool isHost;
  final VoidCallback? onEdit;
  final VoidCallback? onAddPhoto;
  final VoidCallback? onReminders;
  final VoidCallback? onCalendar;
  final VoidCallback? onExport;
  final void Function(String ref)? onOpenPhoto;
  final bool hasReminder;

  const EventCard({
    super.key,
    required this.post,
    required this.myKey,
    required this.nameFor,
    this.onRsvp,
    this.isHost = false,
    this.onEdit,
    this.onAddPhoto,
    this.onReminders,
    this.onCalendar,
    this.onExport,
    this.onOpenPhoto,
    this.hasReminder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = post.payload ?? const {};
    final title = p['title'] as String? ?? 'Event';
    final starts = DateTime.tryParse(p['starts_at'] as String? ?? '')?.toLocal();
    final ends = DateTime.tryParse(p['ends_at'] as String? ?? '')?.toLocal();
    final place = p['place'] as String? ?? '';
    final ticket = p['ticket_url'] as String? ?? '';
    final recurrence = p['recurrence'] as String? ?? 'none';
    final coHosts = (p['co_hosts'] as List?)?.whereType<String>().toList() ?? const <String>[];
    final photos = (p['photos'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
    final rsvps = (p['rsvps'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mine = rsvps[myKey] as String?;
    final going = rsvps.entries.where((e) => e.value == 'going').map((e) => nameFor(e.key)).toList();
    final interested = rsvps.values.where((v) => v == 'interested').length;
    final maybe = rsvps.values.where((v) => v == 'maybe').length;
    final now = DateTime.now();
    final past = starts == null ||
        EventTime.isPast(starts: starts, ends: ends, recurrence: recurrence, now: now);
    final next = starts == null
        ? null
        : EventTime.occurrence(starts: starts, ends: ends, recurrence: recurrence, now: now);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.event, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(title,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            if (isHost && onEdit != null)
              IconButton(
                  tooltip: 'Edit event',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: onEdit),
          ]),
          if (coHosts.isNotEmpty)
            Text('Hosted with ${coHosts.map(nameFor).join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          if (next != null)
            Text(
              '${_fmt(next.starts)}${next.ends != null ? ' – ${_fmtShort(next.ends!, next.starts)}' : ''}',
              style: theme.textTheme.bodyMedium,
            ),
          if (recurrence != 'none')
            Text(EventTime.label(recurrence),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          if (place.isNotEmpty)
            InkWell(
              onTap: () => _openMap(place),
              child: Row(children: [
                Icon(Icons.place_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 4),
                Expanded(
                    child: Text(place,
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.primary))),
              ]),
            ),
          if (ticket.isNotEmpty)
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: () => _open(ticket),
              icon: const Icon(Icons.confirmation_number_outlined, size: 16),
              label: Text(ticket, overflow: TextOverflow.ellipsis),
            ),
          const SizedBox(height: 10),
          if (!past && onRsvp != null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (status, label) in const [
                  ('going', 'Going'),
                  ('interested', 'Interested'),
                  ('maybe', 'Maybe'),
                  ('no', "Can't go"),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: mine == status,
                    onSelected: (_) => onRsvp!(mine == status ? '' : status),
                  ),
              ],
            ),
          if (past)
            Text('This event has passed',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text(
            [
              if (going.isNotEmpty) '${going.length} going: ${going.join(', ')}',
              if (interested > 0) '$interested interested',
              if (maybe > 0) '$maybe maybe',
              if (going.isEmpty && interested == 0 && maybe == 0) 'Nobody has answered yet',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final ref = photos[i]['ref'] as String? ?? '';
                  return GestureDetector(
                    onTap: onOpenPhoto == null ? null : () => onOpenPhoto!(ref),
                    child: MediaThumb(ref: ref, width: 84, height: 84, borderRadius: BorderRadius.circular(10)),
                  );
                },
              ),
            ),
          ],
          if (!past || photos.isNotEmpty || onAddPhoto != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              children: [
                if (onAddPhoto != null)
                  _Small(icon: Icons.add_a_photo_outlined, label: 'Photo', onTap: onAddPhoto!),
                if (!past && onReminders != null)
                  _Small(
                      icon: hasReminder ? Icons.notifications_active : Icons.notifications_none,
                      label: hasReminder ? 'Reminder set' : 'Remind me',
                      onTap: onReminders!),
                if (!past && onCalendar != null)
                  _Small(icon: Icons.calendar_month_outlined, label: 'Calendar', onTap: onCalendar!),
                if (onExport != null)
                  _Small(icon: Icons.ios_share, label: '.ics', onTap: onExport!),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static Future<void> _open(String url) async {
    final uri = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// The place goes to the map app the user has, and nowhere before that.
  static Future<void> _openMap(String place) async {
    final q = Uri.encodeComponent(place);
    final geo = Uri.parse('geo:0,0?q=$q');
    if (await canLaunchUrl(geo)) {
      await launchUrl(geo);
      return;
    }
    await launchUrl(Uri.parse('https://www.openstreetmap.org/search?query=$q'),
        mode: LaunchMode.externalApplication);
  }

  static String _fmt(DateTime d) =>
      '${_weekday(d.weekday)} ${d.day}/${d.month}/${d.year} · ${_hm(d)}';
  static String _fmtShort(DateTime end, DateTime start) =>
      end.day == start.day && end.month == start.month ? _hm(end) : _fmt(end);
  static String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  static String _weekday(int w) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][w - 1];
}

class _Small extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Small({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8)),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      );
}

/// A poll inside a post, on the feed's surface colours.
class FeedPollCard extends StatelessWidget {
  final Post post;
  final String? myKey;
  final String Function(String key) nameFor;
  final void Function(List<int> choices)? onVote;

  const FeedPollCard({
    super.key,
    required this.post,
    required this.myKey,
    required this.nameFor,
    this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final p = post.payload ?? const {};
    final options = (p['options'] as List?)?.cast<String>() ?? const <String>[];
    final votes = (p['votes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final multiple = p['multiple'] == true;
    final anonymous = p['anonymous'] == true;
    final counts = List<int>.filled(options.length, 0);
    for (final v in votes.values) {
      for (final c in (v as List).whereType<int>()) {
        if (c >= 0 && c < counts.length) counts[c]++;
      }
    }
    final total = votes.length;
    final mine = (votes[myKey] as List?)?.whereType<int>().toSet() ?? <int>{};

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${multiple ? 'Choose any' : 'Choose one'}${anonymous ? ' · anonymous' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          for (var i = 0; i < options.length; i++)
            InkWell(
              onTap: onVote == null
                  ? null
                  : () {
                      final next = Set<int>.from(mine);
                      if (mine.contains(i)) {
                        next.remove(i);
                      } else {
                        if (!multiple) next.clear();
                        next.add(i);
                      }
                      onVote!(next.toList()..sort());
                    },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(
                        mine.contains(i)
                            ? (multiple ? Icons.check_box : Icons.radio_button_checked)
                            : (multiple ? Icons.check_box_outline_blank : Icons.radio_button_off),
                        size: 18,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(options[i])),
                      Text('${counts[i]}', style: theme.textTheme.bodySmall),
                    ]),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: total == 0 ? 0 : counts[i] / total,
                        minHeight: 5,
                        backgroundColor: cs.surfaceContainerHighest,
                      ),
                    ),
                    if (!anonymous)
                      Text(
                        votes.entries
                            .where((e) => (e.value as List).contains(i))
                            .map((e) => nameFor(e.key))
                            .join(', '),
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          Text(total == 0 ? 'No votes yet' : '$total vote${total == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Fields for creating an event, returned to the composer.
/// What the event dialog produces.
class EventDraft {
  final String title;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String place;
  final String ticketUrl;
  final String recurrence;
  final List<String> coHosts;

  const EventDraft({
    required this.title,
    required this.startsAt,
    this.endsAt,
    this.place = '',
    this.ticketUrl = '',
    this.recurrence = 'none',
    this.coHosts = const [],
  });
}

/// Make or change an event. [candidates] are the people who could co-host,
/// as (key, name); [initial] fills the form for an edit, and [canPickHosts]
/// is false for a co-host editing somebody else's event.
Future<EventDraft?> showEventDialog(
  BuildContext context, {
  List<(String, String)> candidates = const [],
  EventDraft? initial,
  bool canPickHosts = true,
}) async {
  final title = TextEditingController(text: initial?.title ?? '');
  final place = TextEditingController(text: initial?.place ?? '');
  final ticket = TextEditingController(text: initial?.ticketUrl ?? '');
  DateTime starts = initial?.startsAt ?? DateTime.now().add(const Duration(hours: 1));
  DateTime? ends = initial?.endsAt;
  String recurrence = initial?.recurrence ?? 'none';
  final hosts = <String>{...?initial?.coHosts};
  return showDialog<EventDraft>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(initial == null ? 'New event' : 'Edit event'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: title,
                autofocus: initial == null,
                decoration: const InputDecoration(labelText: 'What'),
                textCapitalization: TextCapitalization.sentences,
              ),
              TextField(
                controller: place,
                decoration: const InputDecoration(labelText: 'Where (optional)'),
                textCapitalization: TextCapitalization.words,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text('Starts ${EventCard._fmt(starts)}'),
                onTap: () async {
                  final picked = await _pickDateTime(ctx, starts);
                  if (picked != null) setState(() => starts = picked);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_outlined),
                title: Text(ends == null ? 'Add an end time' : 'Ends ${EventCard._fmt(ends!)}'),
                trailing: ends == null
                    ? null
                    : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => ends = null)),
                onTap: () async {
                  final picked = await _pickDateTime(ctx, ends ?? starts.add(const Duration(hours: 2)));
                  if (picked != null) setState(() => ends = picked);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: recurrence,
                decoration: const InputDecoration(labelText: 'Repeats'),
                items: [
                  for (final r in EventTime.recurrences)
                    DropdownMenuItem(value: r, child: Text(r == 'none' ? 'Does not repeat' : EventTime.label(r))),
                ],
                onChanged: (v) => setState(() => recurrence = v ?? 'none'),
              ),
              TextField(
                controller: ticket,
                decoration: const InputDecoration(
                    labelText: 'Ticket link (optional)',
                    helperText: 'Shown as a link; nothing is fetched'),
                keyboardType: TextInputType.url,
              ),
              if (canPickHosts && candidates.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('Co-hosts', style: TextStyle(fontWeight: FontWeight.w600)),
                const Text('They can change the details', style: TextStyle(fontSize: 11)),
                for (final (key, name) in candidates)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: hosts.contains(key),
                    title: Text(name),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        hosts.add(key);
                      } else {
                        hosts.remove(key);
                      }
                    }),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (title.text.trim().isEmpty) return;
              Navigator.pop(
                ctx,
                EventDraft(
                  title: title.text.trim(),
                  startsAt: starts,
                  endsAt: ends,
                  place: place.text.trim(),
                  ticketUrl: ticket.text.trim(),
                  recurrence: recurrence,
                  coHosts: hosts.toList(),
                ),
              );
            },
            child: Text(initial == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );
}

Future<DateTime?> _pickDateTime(BuildContext context, DateTime initial) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime.now().subtract(const Duration(days: 1)),
    lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Report a post to the admins of its sphere.
Future<String?> showReportDialog(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Report to the sphere'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This goes to the admins of the sphere the post is in, and to nobody '
            'else. There is no company behind this app to appeal to; the people '
            'who run the sphere decide.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'What is wrong with it'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text.trim().isEmpty ? 'Reported' : controller.text.trim()),
          child: const Text('Report'),
        ),
      ],
    ),
  );
}

/// Caption and an optional sticker for a story.
Future<Map<String, dynamic>?> showStoryComposer(BuildContext context) {
  final caption = TextEditingController();
  final question = TextEditingController();
  final optionA = TextEditingController(text: 'Yes');
  final optionB = TextEditingController(text: 'No');
  final countdownLabel = TextEditingController();
  String sticker = 'none';
  DateTime countdown = DateTime.now().add(const Duration(days: 1));
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your story', style: Theme.of(ctx).textTheme.titleMedium),
              TextField(
                controller: caption,
                decoration: const InputDecoration(labelText: 'Caption (shown over the photo)'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final (id, label) in const [
                    ('none', 'No sticker'),
                    ('poll', 'Poll'),
                    ('question', 'Question'),
                    ('countdown', 'Countdown')
                  ])
                    ChoiceChip(
                        label: Text(label), selected: sticker == id, onSelected: (_) => setState(() => sticker = id)),
                ],
              ),
              if (sticker == 'poll') ...[
                TextField(controller: question, decoration: const InputDecoration(labelText: 'Ask something')),
                Row(children: [
                  Expanded(child: TextField(controller: optionA, decoration: const InputDecoration(labelText: 'Option 1'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: optionB, decoration: const InputDecoration(labelText: 'Option 2'))),
                ]),
              ],
              if (sticker == 'question')
                TextField(controller: question, decoration: const InputDecoration(labelText: 'Ask me anything…')),
              if (sticker == 'countdown') ...[
                TextField(controller: countdownLabel, decoration: const InputDecoration(labelText: 'Counting down to')),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.hourglass_bottom),
                  title: Text(EventCard._fmt(countdown)),
                  onTap: () async {
                    final picked = await _pickDateTime(ctx, countdown);
                    if (picked != null) setState(() => countdown = picked);
                  },
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Answers to a poll or a question come to you as private replies. Nobody else in the sphere sees them.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, {
                    if (caption.text.trim().isNotEmpty) 'overlay': caption.text.trim(),
                    if (sticker == 'poll')
                      'sticker': {
                        'type': 'poll',
                        'question': question.text.trim(),
                        'options': [optionA.text.trim(), optionB.text.trim()],
                      },
                    if (sticker == 'question') 'sticker': {'type': 'question', 'prompt': question.text.trim()},
                    if (sticker == 'countdown')
                      'sticker': {
                        'type': 'countdown',
                        'label': countdownLabel.text.trim(),
                        'until': countdown.toIso8601String(),
                      },
                  }),
                  child: const Text('Share story'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Stickers drawn over a story.
class StorySticker extends StatelessWidget {
  final Map<String, dynamic> sticker;
  final void Function(String answer)? onAnswer;
  const StorySticker({super.key, required this.sticker, this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final type = sticker['type'];
    final box = BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(16));
    if (type == 'poll') {
      final options = (sticker['options'] as List?)?.cast<String>() ?? const [];
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: box,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(sticker['question'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black)),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final o in options)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilledButton.tonal(
                      onPressed: onAnswer == null ? null : () => onAnswer!('Voted: $o'), child: Text(o)),
                ),
            ],
          ),
        ]),
      );
    }
    if (type == 'question') {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: box,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(sticker['prompt'] as String? ?? 'Ask me anything',
              style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black)),
          const SizedBox(height: 6),
          const Text('Reply below to answer', style: TextStyle(color: Colors.black54, fontSize: 12)),
        ]),
      );
    }
    if (type == 'countdown') {
      final until = DateTime.tryParse(sticker['until'] as String? ?? '');
      final left = until == null ? null : until.difference(DateTime.now());
      String remaining;
      if (left == null) {
        remaining = '';
      } else if (left.isNegative) {
        remaining = 'It\'s here';
      } else if (left.inDays >= 1) {
        remaining = '${left.inDays}d ${left.inHours % 24}h';
      } else {
        remaining = '${left.inHours}h ${left.inMinutes % 60}m';
      }
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: box,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(sticker['label'] as String? ?? 'Countdown',
              style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black)),
          Text(remaining, style: const TextStyle(fontSize: 22, color: Colors.black)),
        ]),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Duration helper shared with event rendering.
String describeAgo(DateTime d) => ChatService.describeDuration(DateTime.now().difference(d));
