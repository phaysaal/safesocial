import 'package:flutter/material.dart';

import '../models/post.dart';

/// The one reaction sheet, for posts and comments alike: the kinds in
/// [ReactionKinds], tap one and the sheet closes.
Future<void> showReactionPicker(
  BuildContext context, {
  required void Function(String emoji) onPick,
  String? current,
}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          runSpacing: 8,
          children: [
            for (final kind in ReactionKinds.all)
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.pop(ctx);
                  onPick(kind.$1);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  decoration: kind.$1 == current
                      ? BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        )
                      : null,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(kind.$1, style: const TextStyle(fontSize: 26)),
                      const SizedBox(height: 4),
                      Text(kind.$2,
                          style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A compact "❤️ 3 · 👍 1" line for a set of reactions. Nothing when empty.
class ReactionTally extends StatelessWidget {
  final List<Reaction> reactions;
  final TextStyle? style;

  const ReactionTally({super.key, required this.reactions, this.style});

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final tally = ReactionKinds.tally(reactions);
    return Wrap(
      spacing: 8,
      children: [
        for (final e in tally.entries)
          Text('${e.key} ${e.value}',
              style: style ?? Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
