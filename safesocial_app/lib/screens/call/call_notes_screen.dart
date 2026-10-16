import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/call_notes_service.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';

/// The notes of one call, both sides when both are here, in the order
/// things were said: ours editable and deletable, theirs as they sent them,
/// each marked as engine-made.
class CallNotesScreen extends StatelessWidget {
  final String logId;

  /// The other side, when their notes should be shown beside ours; and one
  /// message to take them from, else every `call_notes` message of theirs
  /// that overlaps our call.
  final String? peer;
  final String? messageId;

  const CallNotesScreen({super.key, required this.logId, this.peer, this.messageId});

  @override
  Widget build(BuildContext context) {
    final notes = context.watch<CallNotesService>();
    final calls = context.read<CallService>();
    final r = notes.recordFor(logId);
    final other = peer ?? r?.peer;
    final theirs = <SharedCallNotes>[];
    if (other != null) {
      final conversation = context.watch<ChatService>().conversations[other] ?? const [];
      for (final m in conversation) {
        if (m.kind != 'call_notes' || m.senderId != other) continue;
        final shared = SharedCallNotes.tryParse(m.payload);
        if (shared == null) continue;
        final wanted = messageId != null
            ? m.id == messageId
            : (r?.overlaps(shared.startedAt, shared.endedAt) ?? false);
        if (wanted) theirs.add(shared);
      }
    }
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (r == null && theirs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Call notes')),
        body: const Center(child: Text('No notes for this call.')),
      );
    }
    final name = other == null ? 'them' : calls.nameFor(other);
    final merged = CallNotesService.merge(
      r?.notes ?? const [],
      theirs.expand((s) => s.notes).toList(),
      theirName: name,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(other == null ? 'Call notes' : 'Notes · $name'),
        actions: [
          if (r != null)
            IconButton(
              tooltip: 'Delete your notes',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete your notes of this call?'),
                    content: theirs.isEmpty ? null : const Text('Theirs stay in the chat.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await notes.deleteAll(logId);
                  if (context.mounted && theirs.isEmpty) Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.tertiaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Each phone noted its own voice, by rules, not by understanding. '
              'Some notes will be wrong and most of the call is not here. '
              '${theirs.isEmpty ? 'Edit or delete anything.' : "Yours can be edited or deleted; $name's are as they sent them."}',
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer),
            ),
          ),
          if (r != null && r.markdown.trim().isNotEmpty)
            _summary(theme, cs, 'YOUR SUMMARY', r.markdown),
          for (final s in theirs)
            if (s.markdown.trim().isNotEmpty)
              _summary(theme, cs, "${name.toUpperCase()}'S SUMMARY", s.markdown),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('NOTES · ${merged.length}, IN ORDER',
                style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          for (final n in merged)
            ListTile(
              leading: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_clock(n.at), style: theme.textTheme.labelSmall),
                  Text(n.kindLabel, style: theme.textTheme.labelSmall?.copyWith(color: cs.primary)),
                ],
              ),
              title: Text(n.description),
              subtitle: Text([
                n.speaker ?? 'You',
                if (n.owner != null) 'Owner: ${n.owner}',
                if (n.deadline != null) 'By: ${n.deadline}',
                'Engine-made${n.uncertain ? ', uncertain' : ''}',
              ].join(' · ')),
              trailing: n.speaker != null || r == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => notes.deleteNote(logId, n.id),
                    ),
              onTap: n.speaker != null || r == null
                  ? null
                  : () async {
                      final c = TextEditingController(text: n.description);
                      final text = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Edit note'),
                          content: TextField(controller: c, maxLines: 4, autofocus: true),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
                          ],
                        ),
                      );
                      if (text != null) await notes.editNote(logId, n.id, text);
                    },
            ),
        ],
      ),
    );
  }

  Widget _summary(ThemeData theme, ColorScheme cs, String title, String md) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(title, style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SelectableText(_plain(md), style: theme.textTheme.bodyMedium),
          ),
        ],
      );

  static String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// The engine writes Markdown; shown as plain lines with its headings kept.
  static String _plain(String md) => md
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*'), '')
      .trim();
}
