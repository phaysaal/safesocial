import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/identity_service.dart';
import '../../services/theme_service.dart';

/// Settings screen — privacy, appearance, identity export.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final themeService = context.watch<ThemeService>();
    final identityService = context.watch<IdentityService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Settings',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        children: [
          // ── Appearance ────────────────────────────────────
          _SectionHeader(title: 'Appearance'),
          ListTile(
            leading: Icon(
              themeService.isDark ? Icons.dark_mode : Icons.light_mode,
              color: cs.primary,
            ),
            title: const Text('Dark Mode'),
            trailing: Switch.adaptive(
              value: themeService.isDark,
              onChanged: (_) => themeService.toggle(),
              activeColor: cs.primary,
            ),
          ),
          const Divider(indent: 56),

          // ── Privacy & Security ────────────────────────────
          _SectionHeader(title: 'Privacy & Security'),
          ListTile(
            leading: Icon(Icons.key, color: cs.primary),
            title: const Text('Export Identity'),
            subtitle: const Text('Copy your private key for backup'),
            onTap: () async {
              final key = await identityService.exportIdentity();
              if (context.mounted) {
                Clipboard.setData(ClipboardData(text: key));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Identity key copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.shield_outlined, color: cs.primary),
            title: const Text('Encryption'),
            subtitle: const Text('End-to-end XChaCha20-Poly1305'),
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
            onTap: () {},
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.visibility_off_outlined, color: cs.primary),
            title: const Text('Network Privacy'),
            subtitle: const Text('Onion routing via Veilid private routes'),
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
            onTap: () {},
          ),
          const Divider(indent: 56),

          // ── About ─────────────────────────────────────────
          _SectionHeader(title: 'About'),
          ListTile(
            leading: Icon(Icons.info_outline, color: cs.primary),
            title: const Text('About SafeSocial'),
            subtitle: const Text('Part of the SafeSelf project'),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'SafeSocial',
                applicationVersion: '0.1.0',
                applicationLegalese:
                    'Your data. Your network. Your rules.\n\n'
                    'SafeSocial is a decentralized peer-to-peer social network '
                    'built on Veilid. No servers, no accounts, no metadata '
                    'collection.',
              );
            },
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.code, color: cs.primary),
            title: const Text('Version'),
            subtitle: const Text('0.1.0 (development)'),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
