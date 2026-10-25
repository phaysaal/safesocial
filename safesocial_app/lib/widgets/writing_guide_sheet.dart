import 'package:flutter/material.dart';

import '../models/writing_guide.dart';

/// Asks, in the order a message goes, and hands back the person's own words.
/// There is nothing here to tap and send: the draft starts empty and only
/// what the person types goes into it. Returns the draft, or null.
Future<String?> showWritingGuide(
  BuildContext context, {
  required String name,
  Occasion? occasion,
  String initial = '',
  VoidCallback? onSpeakInstead,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _GuideSheet(
      name: name,
      occasion: occasion,
      initial: initial,
      onSpeakInstead: onSpeakInstead,
    ),
  );
}

class _GuideSheet extends StatefulWidget {
  final String name;
  final Occasion? occasion;
  final String initial;
  final VoidCallback? onSpeakInstead;
  const _GuideSheet({required this.name, this.occasion, required this.initial, this.onSpeakInstead});

  @override
  State<_GuideSheet> createState() => _GuideSheetState();
}

class _GuideSheetState extends State<_GuideSheet> {
  Occasion? _occasion;
  late final TextEditingController _draft = TextEditingController(text: widget.initial);
  int _step = 0;
  bool _noticed = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _occasion = widget.occasion;
    _draft.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final o = _occasion;
    final questions = o == null ? const <GuideQuestion>[] : WritingGuide.questionsFor(o, name: widget.name);
    final q = _step < questions.length ? questions[_step] : null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('To ${widget.name}', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Your words only. The questions are here to help you find them and are not sent.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (o == null) ...[
                Text('What is it for?', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in Occasion.values)
                      ChoiceChip(
                        label: Text(k.label),
                        selected: false,
                        onSelected: (_) => setState(() => _occasion = k),
                      ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Chip(label: Text(o.label), visualDensity: VisualDensity.compact),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        _occasion = null;
                        _step = 0;
                      }),
                      child: const Text('Change'),
                    ),
                  ],
                ),
                if (q != null) ...[
                  Text(q.step.toUpperCase(),
                      style: TextStyle(color: cs.primary, fontSize: 11, fontWeight: FontWeight.w600)),
                  Text(q.text, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _step++),
                        child: Text(_step + 1 < questions.length ? 'Next question' : 'That is all'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _step = questions.length),
                        child: const Text('No more questions'),
                      ),
                    ],
                  ),
                ],
              ],
              TextField(
                controller: _draft,
                autofocus: true,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  hintText: 'Write here, in your own way.',
                  border: OutlineInputBorder(),
                ),
                onChanged: (text) {
                  // Once, gently, and only after there is enough to read.
                  if (_noticed) return;
                  final n = WritingGuide.notice(text, name: widget.name);
                  if (n != null && text.trim().length > 80) {
                    _noticed = true;
                    setState(() => _notice = n);
                  }
                },
              ),
              if (_notice != null && WritingGuide.notice(_draft.text, name: widget.name) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_notice!, style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary)),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (widget.onSpeakInstead != null)
                    TextButton.icon(
                      icon: const Icon(Icons.mic_none),
                      label: const Text('Say it instead'),
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onSpeakInstead!();
                      },
                    ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: WritingGuide.canSend(_draft.text) ? () => Navigator.pop(context, _draft.text.trim()) : null,
                    child: const Text('Use these words'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
