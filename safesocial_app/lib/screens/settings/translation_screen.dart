import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/translation_service.dart';

/// Opt-in translation on the device. Says in plain words where the models
/// come from and what never leaves the phone.
class TranslationScreen extends StatelessWidget {
  const TranslationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TranslationService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Translation')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: Icon(Icons.translate, color: cs.primary),
            title: const Text('Translate on this device'),
            subtitle: const Text(
                'Off, nothing here does anything. On, "Translate" appears on posts, comments and messages. '
                'The words you translate never leave the phone. Each language needs a model, downloaded once from Google\'s servers when you ask; '
                'Spheres bundles none.'),
            isThreeLine: true,
            value: t.enabled,
            onChanged: t.setEnabled,
          ),
          ListTile(
            leading: Icon(Icons.flag_outlined, color: cs.primary),
            title: const Text('Translate into'),
            subtitle: Text(t.languages.where((l) => l.$1 == t.target).map((l) => l.$2).firstOrNull ?? t.target),
            trailing: DropdownButton<String>(
              value: t.languages.any((l) => l.$1 == t.target) ? t.target : null,
              items: [for (final l in t.languages) DropdownMenuItem(value: l.$1, child: Text(l.$2))],
              onChanged: (v) => v == null ? null : t.setTarget(v),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Models on this device', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Translating needs the model of the language you read and of the one you translate into. A model is 30 to 70 MB.',
                style: theme.textTheme.bodySmall),
          ),
          for (final (code, name) in t.languages)
            FutureBuilder<bool>(
              future: t.hasModel(code).catchError((_) => false),
              builder: (context, snap) {
                final has = snap.data ?? false;
                return ListTile(
                  dense: true,
                  title: Text(name),
                  subtitle: Text(has ? 'On this device' : 'Not downloaded'),
                  trailing: IconButton(
                    icon: Icon(has ? Icons.delete_outline : Icons.download_outlined),
                    tooltip: has ? 'Delete the $name model' : 'Download the $name model from Google',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        if (has) {
                          await t.deleteModel(code);
                        } else {
                          messenger.showSnackBar(SnackBar(content: Text('Downloading the $name model…')));
                          await t.downloadModel(code);
                          messenger.showSnackBar(SnackBar(content: Text('$name is ready')));
                        }
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('$e')));
                      }
                    },
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
