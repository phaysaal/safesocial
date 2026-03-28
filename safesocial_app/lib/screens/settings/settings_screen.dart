import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/backup_service.dart';
import '../../services/identity_service.dart';
import '../../services/sync_service.dart';
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
    final syncService = context.watch<SyncService>();
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

          // ── Identity ──────────────────────────────────
          _SectionHeader(title: 'Identity & Multi-Device'),
          ListTile(
            leading: Icon(Icons.devices, color: cs.primary),
            title: const Text('Link New Device'),
            subtitle: const Text('Clone identity to a tablet or computer'),
            onTap: () => _showLinkDeviceDialog(context, syncService),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.qr_code_scanner, color: cs.primary),
            title: const Text('Clone Identity from Device'),
            subtitle: const Text('Set up this device as a secondary'),
            onTap: () => _showCloneIdentityDialog(context, syncService),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.people_alt, color: cs.primary),
            title: const Text('Social Recovery'),
            subtitle: const Text('Trust friends to help recover your account'),
            onTap: () => context.push('/settings/recovery'),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.key, color: cs.primary),
            title: const Text('Export Private Key'),
            subtitle: const Text('Copy for backup or multi-device use'),
            onTap: () async {
              final key = await identityService.exportIdentity();
              if (context.mounted) {
                Clipboard.setData(ClipboardData(text: key));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Private key copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.input, color: cs.primary),
            title: const Text('Import Private Key'),
            subtitle: const Text('Restore identity on this device'),
            onTap: () => _showImportKeyDialog(context),
          ),
          const Divider(indent: 56),

          // ── Backup & Restore ──────────────────────────
          _SectionHeader(title: 'Backup & Restore'),
          ListTile(
            leading: Icon(Icons.backup, color: cs.primary),
            title: const Text('Create Backup'),
            subtitle: const Text('Save all data to an encrypted file'),
            onTap: () => _createBackup(context, backupService),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.restore, color: cs.primary),
            title: const Text('Restore from Backup'),
            subtitle: const Text('Load data from a backup file'),
            onTap: () => _showRestoreDialog(context, backupService),
          ),
          const Divider(indent: 56),

          // ── Privacy & Security ──────────────────────────
          _SectionHeader(title: 'Privacy & Security'),
          ListTile(
            leading: Icon(Icons.shield_outlined, color: cs.primary),
            title: const Text('Encryption'),
            subtitle: const Text('End-to-end XChaCha20-Poly1305'),
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.visibility_off_outlined, color: cs.primary),
            title: const Text('Network Privacy'),
            subtitle: const Text('Onion routing via Veilid private routes'),
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
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
                applicationVersion: '0.1.0',
                applicationLegalese:
                    'Your data. Your network. Your rules.\n\n'
                    'Spheres is a decentralized peer-to-peer social network '
                    'built on Veilid.',
              );
            },
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.code, color: cs.primary),
            title: const Text('Version'),
            subtitle: const Text('0.1.0 (development)'),
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

  void _showLinkDeviceDialog(BuildContext context, SyncService syncService) {
    final pairingCode = syncService.startPrimaryLinking();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Link New Device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Scan this code with your secondary device to clone your identity.'),
            const SizedBox(height: 24),
            SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: 'spheres-sync:$pairingCode',
                version: QrVersions.auto,
                eyeStyle: QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Theme.of(context).colorScheme.primary,
                ),
                dataModuleStyle: QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Waiting for connection...', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              syncService.stopLinking();
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showCloneIdentityDialog(BuildContext context, SyncService syncService) {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clone Identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the pairing code shown on your primary device.'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Pairing Code',
                hintText: 'Enter code from primary device',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final code = controller.text.trim();
              if (code.isNotEmpty) {
                syncService.startSecondaryLinking(code);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Linking started...')),
                );
              }
            },
            child: const Text('Start Linking'),
          ),
        ],
      ),
    );
  }

  void _showImportKeyDialog(BuildContext context) {
    final controller = TextEditingController();
    final nameController = TextEditingController();
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Private Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Paste the private key exported from another device to restore your identity.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Private Key JSON',
                hintText: 'Paste exported key here',
              ),
              maxLines: 3,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'Your name on this device',
              ),
              textCapitalization: TextCapitalization.words,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final key = controller.text.trim();
              if (key.isEmpty) return;
              final success = await context.read<IdentityService>().importIdentity(
                    key,
                    displayName: nameController.text.trim().isNotEmpty
                        ? nameController.text.trim()
                        : null,
                  );
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success ? 'Identity restored successfully' : 'Invalid key format',
                    ),
                  ),
                );
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  Future<void> _createBackup(BuildContext context, BackupService backupService) async {
    final passphraseController = TextEditingController();

    final passphrase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Set a passphrase to encrypt your backup. Leave empty for unencrypted.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passphraseController,
              decoration: const InputDecoration(
                labelText: 'Passphrase (optional)',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, passphraseController.text),
            child: const Text('Create Backup'),
          ),
        ],
      ),
    );

    if (passphrase == null) return;

    try {
      final filePath = await backupService.createBackup(
        passphrase: passphrase.isNotEmpty ? passphrase : null,
      );
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

    final passphraseController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                      // Ask for passphrase
                      final pp = await showDialog<String>(
                        context: context,
                        builder: (ctx2) => AlertDialog(
                          title: const Text('Enter Passphrase'),
                          content: TextField(
                            controller: passphraseController,
                            decoration: const InputDecoration(
                              labelText: 'Passphrase (if encrypted)',
                            ),
                            obscureText: true,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx2),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  Navigator.pop(ctx2, passphraseController.text),
                              child: const Text('Restore'),
                            ),
                          ],
                        ),
                      );
                      if (pp == null) return;
                      try {
                        await backupService.restoreBackup(
                          backups[i].path,
                          passphrase: pp.isNotEmpty ? pp : null,
                        );
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
