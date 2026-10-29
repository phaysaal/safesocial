import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/abuse_report.dart';
import '../services/report_service.dart';
import '../services/terms.dart';

/// "Report to Spheres": a reason, a note, and the choice to include what is
/// being reported. Says before sending exactly what goes and who can read it.
Future<void> showReportToSpheres(
  BuildContext context, {
  required ReportSubject subject,
  String? subjectId,
  String? author,
  String? authorName,
  String? text,
  List<String> mediaRefs = const [],
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ReportSheet(
      subject: subject,
      subjectId: subjectId,
      author: author,
      authorName: authorName,
      text: text,
      mediaRefs: mediaRefs,
    ),
  );
  if (sent == true) {
    messenger.showSnackBar(const SnackBar(content: Text('Sent to the people who run Spheres. Thank you.')));
  }
}

class _ReportSheet extends StatefulWidget {
  final ReportSubject subject;
  final String? subjectId, author, authorName, text;
  final List<String> mediaRefs;
  const _ReportSheet({
    required this.subject,
    this.subjectId,
    this.author,
    this.authorName,
    this.text,
    this.mediaRefs = const [],
  });

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _reason;
  bool _include = true;
  bool _sending = false;
  String? _error;
  final _note = TextEditingController();

  bool get _hasContent => (widget.text?.trim().isNotEmpty ?? false) || widget.mediaRefs.isNotEmpty;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final media = _include ? await ReportService.mediaFor(widget.mediaRefs) : const <String>[];
    final report = ReportService.build(
      reason: reason,
      note: _note.text,
      subject: widget.subject,
      subjectId: widget.subjectId,
      author: widget.author,
      authorName: widget.authorName,
      text: _include ? widget.text : null,
      media: media,
    );
    final error = await ReportService.send(report);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _sending = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Report to Spheres', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'This goes to the people who run Spheres, not to the sphere. It is sealed on your '
                'phone so only they can read it; the relay cannot. Your own identity is not included.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              for (final r in ReportReason.values)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_reason == r ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: _reason == r ? cs.primary : null),
                  title: Text(r.label),
                  onTap: () => setState(() => _reason = r),
                ),
              if (_reason == ReportReason.childSafety || _reason == ReportReason.selfHarm)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    _reason == ReportReason.childSafety
                        ? 'If a child is in danger now, call the police first. Child sexual abuse material '
                            'is reported to the authorities as the law requires.'
                        : 'If someone is in danger now, call your local emergency number. Helplines are in '
                            'Settings, "If you need someone now".',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ),
              TextField(
                controller: _note,
                maxLength: AbuseReport.maxNote,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'What happened (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_hasContent)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include what you are reporting'),
                  subtitle: const Text('The words and up to three pictures, so it can be reviewed'),
                  value: _include,
                  onChanged: (v) => setState(() => _include = v),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Not sent: $_error', style: TextStyle(color: cs.error)),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => launchUrl(Uri.parse(Terms.url), mode: LaunchMode.externalApplication),
                    child: const Text('The rules'),
                  ),
                  const Spacer(),
                  TextButton(onPressed: _sending ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
                  FilledButton(
                    onPressed: _reason == null || _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Send report'),
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
