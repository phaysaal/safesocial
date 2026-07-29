import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../services/backup_service.dart';
import '../../services/identity_service.dart';
import '../../services/theme_service.dart';

/// Settings screen — privacy, appearance, identity, backup.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final themeService = context.watch<ThemeService>();
    final identityService = context.watch<IdentityService>();
    final backupService = BackupService();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Settings',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        children: [
          // ── Appearance ──────────────────────────────────
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
            ),
          ),
          const Divider(indent: 56),

          // ── Security status ────────────────────────────
          _SectionHeader(title: 'Security Status'),
          const _PreAlphaBanner(),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.warning_amber_outlined, color: cs.error),
            title: const Text('Message Encryption'),
            subtitle: const Text(
              'Placeholder cipher — not secure. Messages are obscured, not '
              'protected. Assume the relay operator can read them.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.error_outline, color: cs.error, size: 20),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.warning_amber_outlined, color: cs.error),
            title: const Text('Network Privacy'),
            subtitle: const Text(
              'All traffic passes through one Cloudflare relay, which can see '
              'who communicates with whom.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.error_outline, color: cs.error, size: 20),
          ),
          const Divider(indent: 56),

          // ── Identity ──────────────────────────────────
          _SectionHeader(title: 'Identity & Multi-Device'),
          const _UnavailableTile(
            icon: Icons.devices,
            title: 'Link New Device',
            reason: 'Device linking never completed — the two devices join '
                'different relay rooms. Disabled until rebuilt.',
          ),
          const Divider(indent: 56),
          const _UnavailableTile(
            icon: Icons.people_alt,
            title: 'Social Recovery',
            reason: 'Guardian shards were never generated or sent. Disabled '
                'until implemented, so it cannot be relied on.',
          ),
          const Divider(indent: 56),
          const _UnavailableTile(
            icon: Icons.key,
            title: 'Export / Import Private Key',
            reason: 'Passphrase encryption was a placeholder that discarded '
                'the key. Use Create Backup below instead.',
          ),
          const Divider(indent: 56),

          // ── Backup & Restore ──────────────────────────
          _SectionHeader(title: 'Backup & Restore'),
          ListTile(
            leading: Icon(Icons.backup, color: cs.primary),
            title: const Text('Create Backup'),
            subtitle: const Text('Unencrypted — contains your private key'),
            onTap: () => _createBackup(context, backupService),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.restore, color: cs.primary),
            title: const Text('Restore from Backup'),
            subtitle: const Text('Replaces the identity on this device'),
            onTap: () => _showRestoreDialog(context, backupService),
          ),
          const Divider(indent: 56),

          // ── Privacy & Security ──────────────────────────
          _SectionHeader(title: 'Privacy & Security'),
          ListTile(
            leading: Icon(Icons.delete_forever, color: cs.error),
            title: Text('Reset Everything', style: TextStyle(color: cs.error)),
            subtitle: const Text('Wipe all local data, including backups'),
            onTap: () => _showResetDialog(context, identityService),
          ),
          const Divider(indent: 56),

          // ── About ──────────────────────────────────────
          _SectionHeader(title: 'About'),
          ListTile(
            leading: Icon(Icons.info_outline, color: cs.primary),
            title: const Text('About Spheres'),
            subtitle: const Text('Part of the SafeSelf project'),
            onTap: () {
              showAboutDialog(
                context: context,
                applicationName: 'Spheres',
                applicationVersion: AppInfo.version,
                applicationLegalese:
                    'Your data. Your network. Your rules.\n\n'
                    'Spheres is an early prototype of a private social network. '
                    'Its encryption is not yet implemented and its traffic is '
                    'relayed through a single server. Do not use it for '
                    'anything sensitive.',
              );
            },
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.code, color: cs.primary),
            title: const Text('Version'),
            subtitle: const Text('${AppInfo.version} (${AppInfo.channel})'),
          ),
          const Divider(indent: 56),

          // ── Developer ──────────────────────────────────
          _SectionHeader(title: 'Developer'),
          ListTile(
            leading: Icon(Icons.terminal, color: cs.primary),
            title: const Text('Debug Console'),
            subtitle: const Text('View P2P network and messaging logs'),
            onTap: () => context.push('/debug'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showResetDialog(BuildContext context, IdentityService service) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Everything?'),
        content: const Text(
          'This will permanently delete your identity, contacts, and all '
          'messages from this device — including any backup files saved here.\n\n'
          'Your identity cannot be recovered afterwards. If you want to keep '
          'it, copy your backup file off this device first.\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              await service.resetEverything();
              if (ctx.mounted) {
                Navigator.pop(ctx);
                context.go('/onboarding');
              }
            },
            child: const Text('Reset', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _createBackup(BuildContext context, BackupService backupService) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Backup'),
        content: const Text(
          'The backup file will contain your private key in readable form.\n\n'
          'Passphrase encryption is not available in this build, so anyone who '
          'obtains the file can take over your identity. Store it somewhere you '
          'trust, and delete it when you no longer need it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Create Anyway'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final filePath = await backupService.createBackup();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backup saved to $filePath'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup failed: $e')),
        );
      }
    }
  }

  Future<void> _showRestoreDialog(BuildContext context, BackupService backupService) async {
    final theme = Theme.of(context);
    final backups = await backupService.listBackups();

    if (!context.mounted) return;

    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No backup files found')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Restoring replaces the identity currently on this device. That '
              'identity cannot be recovered afterwards.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text('${backups.length} backup(s) found:', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: backups.length,
                itemBuilder: (ctx, i) {
                  final name = backups[i].path.split('/').last;
                  return ListTile(
                    dense: true,
                    title: Text(name, style: const TextStyle(fontSize: 12)),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx2) => AlertDialog(
                          title: const Text('Replace this identity?'),
                          content: Text(
                            'Restore "$name"?\n\n'
                            'Your current identity, contacts, and posts will be '
                            'overwritten and cannot be brought back.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx2, false),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () => Navigator.pop(ctx2, true),
                              child: const Text('Restore'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      try {
                        await backupService.restoreBackup(backups[i].path);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Backup restored. Restart the app to apply.'),
                            ),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Restore failed: $e')),
                          );
                        }
                      }
                    },
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
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

/// Banner stating the build's overall maturity, shown above the security rows.
class _PreAlphaBanner extends StatelessWidget {
  const _PreAlphaBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, color: cs.onErrorContainer, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Pre-alpha build. The privacy features described in this app are '
              'still being built and do not protect you yet. Do not use Spheres '
              'for anything you need kept private.',
              style: TextStyle(color: cs.onErrorContainer, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// A feature that has been deliberately disabled, with the reason shown.
///
/// These features previously reported success while doing nothing, which is
/// worse than being absent — users relied on them.
class _UnavailableTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String reason;

  const _UnavailableTile({
    required this.icon,
    required this.title,
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = cs.onSurface.withValues(alpha: 0.38);
    return ListTile(
      enabled: false,
      leading: Icon(icon, color: disabled),
      title: Row(
        children: [
          Flexible(child: Text(title, style: TextStyle(color: disabled))),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'UNAVAILABLE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(reason, style: TextStyle(color: disabled, fontSize: 12)),
      isThreeLine: true,
    );
  }
}
