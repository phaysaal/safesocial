import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/advert.dart';
import '../../services/ad_service.dart';

/// Which kinds of advert this phone would show, and whether any are shown
/// at all. Says what the plan allows and what never leaves the phone.
class AdvertsScreen extends StatelessWidget {
  const AdvertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ads = context.watch<AdService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final choice = ads.choice;
    final atFloor = !choice.canTurnOneOff;
    return Scaffold(
      appBar: AppBar(title: const Text('Advertisements')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(_statusIcon(ads.state), color: cs.primary),
            title: Text(_statusTitle(ads)),
            subtitle: Text(_statusLine(ads)),
            isThreeLine: true,
          ),
          ListTile(
            leading: Icon(Icons.shield_outlined, color: cs.primary),
            title: const Text('How it works'),
            subtitle: const Text(
              'Like a break on television: after twenty minutes of watching, one advert on Home, '
              'until you close it. The phone fetches the whole catalogue and picks one itself from '
              'the categories you keep on. Nothing you do, nothing you choose here and nothing about '
              'what was shown is sent anywhere.',
            ),
            isThreeLine: true,
          ),
          ListTile(
            leading: Icon(Icons.workspace_premium_outlined, color: cs.primary),
            title: Text(choice.plan == AdPlan.paid ? 'Paid plan' : 'Free plan'),
            subtitle: Text(
              choice.plan == AdPlan.paid
                  ? 'Every category may be turned off.'
                  : 'Keeps at least ${AdPlan.freeMinimum} categories on. '
                      'A paid plan, on which every one may be off, is not available yet.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'CATEGORIES · ${choice.on.length} of ${AdCategory.all.length} on',
              style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (atFloor && choice.plan == AdPlan.free)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'At the free plan\'s floor: turn one on before turning another off.',
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          for (final c in AdCategory.all)
            SwitchListTile(
              title: Text(c.label),
              value: choice.isOn(c.id),
              // Off is refused at the floor; the switch says so by being
              // disabled rather than snapping back.
              onChanged: choice.isOn(c.id) && atFloor
                  ? null
                  : (v) => ads.setCategory(c.id, v),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'FOR TESTING',
              style: TextStyle(color: cs.primary, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: Icon(Icons.link, color: cs.primary),
            title: const Text('Catalogue address'),
            subtitle: Text(ads.testUrl?.toString() ??
                'Not set: this phone uses what Spheres carries. Set one to try the slot with a catalogue of your own.'),
            isThreeLine: ads.testUrl == null,
            onTap: () => _editUrl(context, ads),
          ),
          ListTile(
            leading: Icon(Icons.refresh, color: cs.primary),
            title: const Text('Fetch the catalogue again'),
            enabled: ads.catalogue.offersAdverts,
            onTap: ads.catalogue.offersAdverts ? ads.refreshCatalogue : null,
          ),
          ListTile(
            leading: Icon(Icons.play_arrow_outlined, color: cs.primary),
            title: const Text('Fill the slot now'),
            subtitle: const Text('As if twenty minutes had passed; the advert appears on Home.'),
            enabled: ads.eligibleCount > 0 && ads.current == null,
            onTap: ads.eligibleCount > 0 && ads.current == null
                ? () {
                    final shown = ads.fillSlotNow();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(shown ? 'The slot is filled; see Home.' : 'Nothing to show.'),
                    ));
                  }
                : null,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _editUrl(BuildContext context, AdService ads) async {
    final controller = TextEditingController(text: ads.testUrl?.toString() ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Catalogue address'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'https://example.org/catalogue.json',
            helperText: 'A version 1 catalogue. The whole document is fetched; nothing about this phone is sent.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Use Spheres\' own')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || !context.mounted) return;
    try {
      await ads.setTestUrl(result.isEmpty ? null : Uri.parse(result));
    } on ArgumentError {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The address must start with http:// or https://')));
    }
  }

  IconData _statusIcon(CatalogueState s) => switch (s) {
        CatalogueState.notOffered => Icons.tv_off_outlined,
        CatalogueState.unknown => Icons.hourglass_empty,
        CatalogueState.ready => Icons.tv_outlined,
        CatalogueState.failed => Icons.cloud_off_outlined,
      };

  String _statusTitle(AdService ads) => switch (ads.state) {
        CatalogueState.notOffered => 'No advertisements are shown at present',
        CatalogueState.unknown => 'Catalogue not fetched yet',
        CatalogueState.ready => ads.adverts.isEmpty
            ? 'The catalogue is empty'
            : '${ads.adverts.length} adverts on offer, ${ads.eligibleCount} in your categories',
        CatalogueState.failed => 'The catalogue could not be fetched',
      };

  String _statusLine(AdService ads) => switch (ads.state) {
        CatalogueState.notOffered =>
          'Spheres carries none today. Your choices below are kept so they apply the day it does.',
        CatalogueState.unknown => 'It is fetched once at each start.',
        CatalogueState.ready =>
          'One is shown on Home after every twenty minutes of watching.',
        CatalogueState.failed =>
          '${ads.failure ?? 'No answer'}. Whatever was fetched before still applies.',
      };
}
