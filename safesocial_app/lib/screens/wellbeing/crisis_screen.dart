import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where to turn when things are hard. Plain text, kept in the app; nothing
/// is fetched and nobody is told you looked.
class CrisisScreen extends StatelessWidget {
  const CrisisScreen({super.key});

  static const _lines = <(String, String, String)>[
    ('Anywhere', 'Befrienders Worldwide lists helplines by country', 'https://www.befrienders.org'),
    ('Anywhere', 'Find A Helpline', 'https://findahelpline.com'),
    ('France', '3114, free, 24 hours', 'tel:3114'),
    ('United Kingdom and Ireland', 'Samaritans, 116 123, free, 24 hours', 'tel:116123'),
    ('United States and Canada', '988 Suicide and Crisis Lifeline, call or text 988', 'tel:988'),
    ('Bangladesh', 'Kaan Pete Roi, +880 9612 119911', 'tel:+8809612119911'),
    ('India', 'Tele-MANAS, 14416, free, 24 hours', 'tel:14416'),
    ('Germany', 'Telefonseelsorge, 0800 111 0 111, free, 24 hours', 'tel:08001110111'),
    ('Australia', 'Lifeline, 13 11 14, 24 hours', 'tel:131114'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('If you need someone now')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'If you are in immediate danger, call your local emergency number. '
            'If you are struggling, talking to someone helps, and a helpline is there for exactly that. '
            'These numbers are kept in the app; opening this page tells nobody.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          for (final (where, what, link) in _lines)
            ListTile(
              leading: Icon(link.startsWith('tel:') ? Icons.call_outlined : Icons.public, color: theme.colorScheme.primary),
              title: Text(what),
              subtitle: Text(where),
              onTap: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
            ),
          const SizedBox(height: 16),
          Text('You can also message a contact you trust from the Chat tab, or take a break: Settings, Your time here, Pause.',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
