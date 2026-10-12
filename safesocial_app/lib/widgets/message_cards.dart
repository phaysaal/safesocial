import 'package:flutter/material.dart';

import '../crypto/blob.dart';
import '../services/file_bridge.dart';
import '../services/media_service.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart';

/// A poll inside a message, with live results.
///
/// Votes live in the message payload under the voter's key, or under a
/// per-poll hash when the poll is anonymous. Every device tallies the same
/// data, so there is no server to ask and nothing to trust but the signatures
/// the votes arrived under.
class PollCard extends StatelessWidget {
  final Message message;
  final String? myKey;
  final void Function(List<int> choices)? onVote;
  final String Function(String key)? nameFor;

  const PollCard({
    super.key,
    required this.message,
    required this.myKey,
    this.onVote,
    this.nameFor,
  });

  @override
  Widget build(BuildContext context) {
    final payload = message.payload ?? const {};
    final question = payload['question'] as String? ?? message.content;
    final options = (payload['options'] as List?)?.cast<String>() ?? const <String>[];
    final votes = (payload['votes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final multiple = payload['multiple'] == true;
    final anonymous = payload['anonymous'] == true;

    final counts = List<int>.filled(options.length, 0);
    for (final v in votes.values) {
      for (final c in (v as List).whereType<int>()) {
        if (c >= 0 && c < counts.length) counts[c]++;
      }
    }
    final total = votes.length;
    final mine = (votes[myKey] as List?)?.whereType<int>().toSet() ?? <int>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.poll_outlined, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Expanded(
              child: Text(question,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ],
        ),
        Text(
          '${multiple ? 'Choose any' : 'Choose one'}${anonymous ? ' · anonymous' : ''}',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < options.length; i++)
          _option(context, i, options[i], counts[i], total, mine, multiple, anonymous, votes),
        const SizedBox(height: 4),
        Text(
          total == 0 ? 'No votes yet' : '$total vote${total == 1 ? '' : 's'}',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
      ],
    );
  }

  Widget _option(BuildContext context, int index, String label, int count, int total,
      Set<int> mine, bool multiple, bool anonymous, Map<String, dynamic> votes) {
    final fraction = total == 0 ? 0.0 : count / total;
    final chosen = mine.contains(index);
    final voters = anonymous || nameFor == null
        ? null
        : votes.entries
            .where((e) => (e.value as List).contains(index))
            .map((e) => nameFor!(e.key))
            .join(', ');
    return InkWell(
      onTap: onVote == null
          ? null
          : () {
              final next = Set<int>.from(mine);
              if (chosen) {
                next.remove(index);
              } else {
                if (!multiple) next.clear();
                next.add(index);
              }
              onVote!(next.toList()..sort());
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  chosen
                      ? (multiple ? Icons.check_box : Icons.radio_button_checked)
                      : (multiple ? Icons.check_box_outline_blank : Icons.radio_button_off),
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: const TextStyle(color: Colors.white))),
                Text('$count', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 3),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 5,
                backgroundColor: Colors.white.withValues(alpha: 0.2),
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            if (voters != null && voters.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(voters,
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ask for a poll's question and options.
Future<({String question, List<String> options, bool multiple, bool anonymous})?>
    showCreatePollDialog(BuildContext context) {
  final question = TextEditingController();
  final options = [TextEditingController(), TextEditingController()];
  var multiple = false;
  var anonymous = false;
  return showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('New poll'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: question,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Question'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < options.length; i++)
                TextField(
                  controller: options[i],
                  decoration: InputDecoration(labelText: 'Option ${i + 1}'),
                ),
              TextButton.icon(
                onPressed: options.length >= 10
                    ? null
                    : () => setState(() => options.add(TextEditingController())),
                icon: const Icon(Icons.add),
                label: const Text('Add option'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: multiple,
                title: const Text('Allow several answers'),
                onChanged: (v) => setState(() => multiple = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: anonymous,
                title: const Text('Anonymous votes'),
                subtitle: const Text('Counts are shown; names are not'),
                onChanged: (v) => setState(() => anonymous = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final q = question.text.trim();
              final opts = options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
              if (q.isEmpty || opts.length < 2) return;
              Navigator.pop(ctx, (question: q, options: opts, multiple: multiple, anonymous: anonymous));
            },
            child: const Text('Send'),
          ),
        ],
      ),
    ),
  );
}

/// A shared location, live or fixed.
class LocationCard extends StatelessWidget {
  final Message message;
  final bool isMine;
  final VoidCallback? onStop;

  const LocationCard({super.key, required this.message, required this.isMine, this.onStop});

  @override
  Widget build(BuildContext context) {
    final p = message.payload ?? const {};
    final lat = (p['lat'] as num?)?.toDouble();
    final lng = (p['lng'] as num?)?.toDouble();
    final until = DateTime.tryParse(p['until'] as String? ?? '');
    final updated = DateTime.tryParse(p['updated'] as String? ?? '');
    final live = p['live'] == true && until != null && until.isAfter(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(live ? Icons.my_location : Icons.location_on_outlined,
                size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(live ? 'Live location' : 'Location',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
        if (lat != null && lng != null) ...[
          const SizedBox(height: 4),
          Text('${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13)),
        ],
        Text(
          live
              ? 'Sharing until ${_hm(until)}${updated != null ? ' · updated ${_hm(updated)}' : ''}'
              : (until != null ? 'Sharing ended' : ''),
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            if (lat != null && lng != null)
              _chip(Icons.map_outlined, 'Open in maps', () {
                // Opening a map hands the coordinates to whichever map app the
                // user chose. That is their decision, made per tap.
                launchUrl(Uri.parse('geo:$lat,$lng?q=$lat,$lng'),
                    mode: LaunchMode.externalApplication);
              }),
            if (lat != null && lng != null)
              _chip(Icons.copy, 'Copy', () => Clipboard.setData(ClipboardData(text: '$lat,$lng'))),
            if (live && isMine && onStop != null) _chip(Icons.stop_circle_outlined, 'Stop', onStop!),
          ],
        ),
      ],
    );
  }

  static String _hm(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => ActionChip(
        avatar: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );
}

/// Someone's contact card, shared into a chat. Tapping asks them to connect;
/// they still decide.
class ContactCard extends StatelessWidget {
  final Message message;
  final VoidCallback? onAdd;
  final bool alreadyContact;

  const ContactCard({super.key, required this.message, this.onAdd, this.alreadyContact = false});

  @override
  Widget build(BuildContext context) {
    final p = message.payload ?? const {};
    final name = p['name'] as String? ?? 'Contact';
    final key = p['publicKey'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.contact_page_outlined, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
        if (key.length > 16)
          Text('${key.substring(0, 16)}…',
              style: const TextStyle(color: Colors.white60, fontSize: 11, fontFamily: 'monospace')),
        const SizedBox(height: 6),
        ActionChip(
          avatar: Icon(alreadyContact ? Icons.check : Icons.person_add_alt_1, size: 16),
          label: Text(alreadyContact ? 'Already a contact' : 'Ask to connect',
              style: const TextStyle(fontSize: 12)),
          onPressed: alreadyContact ? null : onAdd,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// Pick a chat or sphere to forward into.
Future<({String id, bool isSphere})?> showForwardSheet(
  BuildContext context, {
  required List<({String id, String name})> contacts,
  required List<({String id, String name})> spheres,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Forward to', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final c in contacts)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(c.name),
                onTap: () => Navigator.pop(ctx, (id: c.id, isSphere: false)),
              ),
            if (spheres.isNotEmpty) const Divider(),
            for (final s in spheres)
              ListTile(
                leading: const Icon(Icons.blur_circular),
                title: Text(s.name),
                onTap: () => Navigator.pop(ctx, (id: s.id, isSphere: true)),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Choose a disappearing-message timer.
Future<Duration?> showDisappearingDialog(BuildContext context, Duration? current) {
  const choices = <(String, Duration?)>[
    ('Off', null),
    ('24 hours', Duration(hours: 24)),
    ('7 days', Duration(days: 7)),
    ('90 days', Duration(days: 90)),
  ];
  return showDialog<Duration?>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Disappearing messages'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'New messages are removed from every device after the time chosen. '
            'Both sides see the setting; either side can change it.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        for (final c in choices)
          RadioListTile<Duration?>(
            value: c.$2,
            groupValue: current,
            title: Text(c.$1),
            onChanged: (_) => Navigator.pop(ctx, c.$2 ?? const Duration()),
          ),
      ],
    ),
  );
}

/// A file of any type: name, size and an Open button. The bytes are fetched
/// like any media; until they are, the card says so.
class FileCard extends StatelessWidget {
  final Message message;
  final VoidCallback? onOpen;
  const FileCard({super.key, required this.message, this.onOpen});

  static String describeSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static IconData iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mime.contains('zip') || mime.contains('compressed')) return Icons.folder_zip_outlined;
    if (mime.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final p = message.payload ?? const {};
    final name = p['name'] as String? ?? message.content;
    final mime = p['mime'] as String? ?? 'application/octet-stream';
    final size = p['size'] is int ? p['size'] as int : 0;
    final ref = message.mediaRefs.isEmpty ? '' : message.mediaRefs.first;
    final fetched = ref.isNotEmpty && BlobRef.tryDecode(ref) == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(iconFor(mime), size: 22, color: Colors.white70),
            const SizedBox(width: 8),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(size > 0 ? '${describeSize(size)} · $mime' : mime,
                    style: const TextStyle(color: Colors.white60, fontSize: 11)),
              ]),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ActionChip(
          avatar: Icon(fetched ? Icons.open_in_new : Icons.downloading, size: 16),
          label: Text(fetched ? 'Open' : 'Fetch and open', style: const TextStyle(fontSize: 12)),
          onPressed: onOpen,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// Fetch a file message's bytes if they are still a blob reference, then
/// hand the file to the device. Errors are shown, never swallowed.
Future<void> openFileMessage(BuildContext context, Message m) async {
  final messenger = ScaffoldMessenger.of(context);
  final p = m.payload ?? const {};
  final name = p['name'] as String? ?? 'file';
  final mime = p['mime'] as String? ?? 'application/octet-stream';
  if (m.mediaRefs.isEmpty) return;
  try {
    var path = m.mediaRefs.first;
    if (BlobRef.tryDecode(path) != null) {
      messenger.showSnackBar(const SnackBar(content: Text('Fetching…'), duration: Duration(seconds: 1)));
      final local = await MediaService.decodeAndSaveFile(path, name: name);
      if (local == null) throw StateError('could not fetch it from the relay');
      path = local;
    }
    await FileBridge.open(path, name: name, mime: mime);
  } on UnsupportedError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message ?? 'Not available here')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not open the file: $e')));
  }
}
