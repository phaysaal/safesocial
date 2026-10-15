import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/advert.dart';

/// The one slot on Home. Marked as sponsored, closable, and able to say why
/// it is here; the link opens outside the app and only when it is http(s),
/// which the model already made sure of.
class AdvertCard extends StatelessWidget {
  final Advert advert;
  final VoidCallback onClose;

  const AdvertCard({super.key, required this.advert, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final link = advert.link;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.campaign_outlined, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Sponsored · ${AdCategory.labelOf(advert.category)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Why this advert?',
                  icon: const Icon(Icons.info_outline, size: 20),
                  onPressed: () => _why(context),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: onClose,
                ),
              ],
            ),
            Text(advert.title, style: theme.textTheme.titleMedium),
            if (advert.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(advert.body, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'By ${advert.sponsor}',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (link != null)
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(link.host),
                    onPressed: () =>
                        launchUrl(link, mode: LaunchMode.externalApplication),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _why(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Why this advert?'),
        content: Text(advert.why),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.push('/settings/adverts');
            },
            child: const Text('Categories'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }
}
