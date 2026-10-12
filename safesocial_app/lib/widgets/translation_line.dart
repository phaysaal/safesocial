import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/translation_service.dart';

/// Ask for a translation of [text] under [id], or clear one that is shown.
/// Errors are shown in a snackbar, in the service's own words.
Future<void> translateInline(BuildContext context, String id, String text) async {
  final t = context.read<TranslationService>();
  if (t.of(id) != null) {
    t.clear(id);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  try {
    await t.translate(id, text);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Bad state: ', ''))));
  }
}

/// The translation of one thing, under the original, with where it came
/// from. Nothing is drawn until one exists. When [text] is given, a small
/// "Translate" link shows while translation is on.
class TranslationLine extends StatelessWidget {
  final String id;
  final String? text;
  final bool onDark;
  const TranslationLine({super.key, required this.id, this.text, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TranslationService>();
    final theme = Theme.of(context);
    final colour = onDark ? Colors.white70 : theme.colorScheme.onSurfaceVariant;
    final tr = t.of(id);
    if (tr != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr.text, style: theme.textTheme.bodyMedium?.copyWith(color: onDark ? Colors.white : null, fontStyle: FontStyle.italic)),
          Text('Translated from ${tr.from} on this device', style: theme.textTheme.labelSmall?.copyWith(color: colour)),
        ]),
      );
    }
    if (t.isBusy(id)) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Translating…', style: theme.textTheme.labelSmall?.copyWith(color: colour)),
      );
    }
    if (text != null && t.enabled && text!.trim().isNotEmpty) {
      return InkWell(
        onTap: () => translateInline(context, id, text!),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('Translate', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
