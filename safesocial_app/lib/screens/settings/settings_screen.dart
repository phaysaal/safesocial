import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../app_info.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/call_config.dart';
import '../../services/relay_config.dart';
import '../../services/sync_service.dart';
import '../../crypto/vault.dart';
import '../../services/backup_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/inbound_events.dart';
import '../../services/notification_service.dart';
import '../../services/wake_service.dart';
import '../../services/app_lock_service.dart';
import '../../services/library_service.dart';
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
            leading: Icon(Icons.lock_outline, color: cs.primary),
            title: const Text('Message Encryption'),
            subtitle: const Text(
              'XChaCha20-Poly1305, keys agreed with X25519. Direct messages '
              'also use a ratchet, so old messages stay closed if this device '
              'is later compromised. Sphere posts do not.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.visibility_off_outlined, color: cs.primary),
            title: const Text('Network Privacy'),
            subtitle: const Text(
              'Relay addresses are derived from shared secrets, so the '
              'operator cannot tell who talks to whom. It still sees message '
              'timing and approximate size.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.lock_outline, color: cs.primary),
            title: const Text('Storage On This Device'),
            subtitle: const Text(
              'Messages, keys and history are encrypted at rest under a key in '
              'the platform keystore. Someone reading this app\'s files still '
              'sees how many conversations exist, but not with whom.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.check_circle, color: cs.secondary, size: 20),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.devices, color: cs.primary),
            title: const Text('Multiple Devices'),
            subtitle: const Text(
              'Each linked device has its own key, certified by your identity. '
              'Contacts send to every device; posts and chats reach them all. '
              'Linked once between two phones; not yet audited.',
            ),
            isThreeLine: true,
            trailing: Icon(Icons.check_circle, color: cs.tertiary, size: 20),
          ),
          const Divider(indent: 56),

          // ── Identity ──────────────────────────────────
          _SectionHeader(title: 'Identity & Devices'),
          if (identityService.thisDeviceRevoked)
            ListTile(
              leading: Icon(Icons.block, color: cs.error),
              title: Text('This device was removed from your identity',
                  style: TextStyle(color: cs.error)),
              subtitle: const Text(
                  'Another of your devices revoked it. Contacts no longer send '
                  'here. Link it again from a device that still works, or reset.'),
            ),
          Builder(builder: (context) {
            final list = context.watch<IdentityService>().deviceList;
            final count = list?.devices.length ?? 1;
            return ListTile(
              leading: Icon(Icons.devices, color: cs.primary),
              title: const Text('Your Devices'),
              subtitle: Text(count == 1
                  ? 'Only this device'
                  : '$count devices share this identity'),
              onTap: () => _showDevicesDialog(context),
            );
          }),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.add_to_home_screen, color: cs.primary),
            title: const Text('Link Another Device'),
            subtitle: const Text('Add a phone or tablet; both work at once'),
            onTap: () => _showLinkDeviceDialog(context, context.read<SyncService>()),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.qr_code_scanner, color: cs.primary),
            title: const Text('Join From Another Device'),
            subtitle: const Text('Enter a pairing code shown on your first device'),
            onTap: () => _showCloneDialog(context, context.read<SyncService>()),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.people_alt, color: cs.primary),
            title: const Text('Social Recovery'),
            subtitle: const Text('Split your identity across trusted people'),
            onTap: () => context.push('/settings/recovery'),
          ),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.key, color: cs.primary),
            title: const Text('Export Private Key'),
            subtitle: const Text('Passphrase-encrypted, for another device'),
            onTap: () => _showExportDialog(context, identityService),
          ),
          const Divider(indent: 56),

          // ── Backup & Restore ──────────────────────────
          _SectionHeader(title: 'Backup & Restore'),
          ListTile(
            leading: Icon(Icons.backup, color: cs.primary),
            title: const Text('Create Backup'),
            subtitle: const Text('Encrypted with a passphrase you choose'),
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

          // ── Network ────────────────────────────────────
          _SectionHeader(title: 'Network'),
          Builder(builder: (context) {
            final config = context.watch<RelayConfig>();
            return ListTile(
              leading: Icon(Icons.dns_outlined, color: cs.primary),
              title: const Text('Relay Server'),
              subtitle: Text(
                config.isCustom
                    ? '${config.host} (self-hosted)'
                    : '${config.host} (default)',
              ),
              onTap: () => _showRelayDialog(context, config),
            );
          }),
          const Divider(indent: 56),
          Builder(builder: (context) {
            final config = context.watch<CallConfig>();
            return ListTile(
              leading: Icon(Icons.call_outlined, color: cs.primary),
              title: const Text('Call Servers'),
              subtitle: Text(config.summary),
              isThreeLine: false,
              onTap: () => _showCallServersDialog(context, config),
            );
          }),
          const Divider(indent: 56),

          // ── Notifications ──────────────────────────────
          _SectionHeader(title: 'Notifications'),
          Builder(builder: (context) {
            final notifications = context.watch<NotificationService>();
            final wake = context.watch<WakeService>();
            return ListTile(
              leading: Icon(Icons.notifications_outlined, color: cs.primary),
              title: const Text('Notifications'),
              subtitle: Text(_notificationSummary(notifications, wake)),
              onTap: () => _showNotificationsDialog(context),
            );
          }),
          const Divider(indent: 56),

          // ── Privacy & Security ──────────────────────────
          _SectionHeader(title: 'Privacy & Security'),
          Builder(builder: (context) {
            final blocked = context
                .watch<ContactService>()
                .contacts
                .where((c) => c.blocked)
                .toList();
            return ListTile(
              leading: Icon(Icons.block, color: cs.primary),
              title: const Text('Blocked Contacts'),
              subtitle: Text(blocked.isEmpty
                  ? 'Nobody is blocked'
                  : '${blocked.length} blocked'),
              onTap: () => _showBlockedDialog(context),
            );
          }),
          const Divider(indent: 56),
          Builder(builder: (context) {
            final feed = context.watch<FeedService>();
            return SwitchListTile(
              secondary: Icon(Icons.visibility_outlined, color: cs.primary),
              title: const Text('Story View Receipts'),
              subtitle: const Text(
                'Let authors see that you watched their story. Turning this '
                'off means you watch without telling them.',
              ),
              isThreeLine: true,
              value: feed.sendViewReceipts,
              onChanged: feed.setSendViewReceipts,
            );
          }),
          const Divider(indent: 56),
          Builder(builder: (context) {
            final chat = context.watch<ChatService>();
            return SwitchListTile(
              secondary: Icon(Icons.edit_outlined, color: cs.primary),
              title: const Text('Typing Indicators'),
              subtitle: const Text(
                'Show people when you are writing to them. Turning this off '
                'also hides when they are writing to you.',
              ),
              isThreeLine: true,
              value: chat.sendTypingSignals,
              onChanged: chat.setSendTypingSignals,
            );
          }),
          Builder(builder: (context) {
            final chat = context.watch<ChatService>();
            return SwitchListTile(
              secondary: Icon(Icons.done_all, color: cs.primary),
              title: const Text('Read receipts'),
              subtitle: const Text(
                  'Tell senders when you have read their messages. Reciprocal: off '
                  'means you do not see theirs either.'),
              value: chat.sendReadReceipts,
              onChanged: chat.setSendReadReceipts,
            );
          }),
          Builder(builder: (context) {
            final library = context.watch<LibraryService>();
            return ListTile(
              leading: Icon(Icons.visibility_off_outlined, color: cs.primary),
              title: const Text('Hidden words'),
              subtitle: Text(library.hiddenWords.isEmpty
                  ? 'Hide posts and messages containing words you choose'
                  : '${library.hiddenWords.length} word(s) hidden'),
              onTap: () async {
                final controller = TextEditingController(text: library.hiddenWords.join('\n'));
                final text = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Hidden words'),
                    content: TextField(
                      controller: controller,
                      maxLines: 6,
                      decoration: const InputDecoration(
                          helperText: 'One per line. Matched on this device only; nothing is deleted.'),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
                    ],
                  ),
                );
                if (text != null) await library.setHiddenWords(text.split('\n'));
              },
            );
          }),
          Builder(builder: (context) {
            final library = context.watch<LibraryService>();
            final lock = context.read<AppLockService>();
            return SwitchListTile(
              secondary: Icon(Icons.fingerprint, color: cs.primary),
              title: const Text('App lock'),
              subtitle: const Text(
                  'Ask for your fingerprint, face or PIN when Spheres comes back to the screen.'),
              value: library.appLock,
              onChanged: (v) async {
                final messenger = ScaffoldMessenger.of(context);
                if (!await lock.isAvailable) {
                  messenger.showSnackBar(const SnackBar(
                      content: Text('This device has no screen lock to check against.')));
                  return;
                }
                if (!await lock.authenticate('Confirm to change the app lock')) return;
                await library.setAppLock(v);
              },
            );
          }),
          const Divider(indent: 56),
          ListTile(
            leading: Icon(Icons.storage_outlined, color: cs.primary),
            title: const Text('Cached Media'),
            subtitle: const Text('Downloaded photos and videos'),
            onTap: () => _showStorageDialog(context),
          ),
          const Divider(indent: 56),
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

  Future<void> _showRelayDialog(BuildContext context, RelayConfig config) async {
    final controller = TextEditingController(text: config.host);
    final messenger = ScaffoldMessenger.of(context);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Relay Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The relay only moves encrypted bytes between addresses it cannot '
              'link to anyone. It holds no keys and no account. You can run the '
              'worker in relay/ yourself and point this at it.\n\n'
              'Both people in a conversation must use a relay that can reach '
              'the same mailbox, so changing this only works if your contacts '
              'change it too.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Hostname',
                hintText: 'relay.example.org',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await config.resetToDefault();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Use default'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final error = await config.setHost(controller.text);
              if (!ctx.mounted) return;
              if (error != null) {
                messenger.showSnackBar(SnackBar(content: Text(error)));
                return;
              }
              Navigator.pop(ctx);
              messenger.showSnackBar(const SnackBar(
                content: Text('Relay changed. Restart the app to reconnect.'),
              ));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Show a pairing code the other device can use.
  ///
  /// The identity travels as a vault keyed by this code, which is shown on
  /// screen and never sent over the relay — so the relay carries only
  /// ciphertext it has no key for.
  Future<void> _showLinkDeviceDialog(
      BuildContext context, SyncService sync) async {
    final code = sync.startPrimaryLinking();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link Another Device'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter this code on the other device. It is the key to your '
                'identity while linking, so read it out or show the screen — '
                'do not send it through a chat app.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              SelectableText(
                code,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 16),
              const Text(
                'The new device gets its own encryption key, certified by your '
                'identity, and a copy of your contacts, spheres and history. '
                'Both devices then work at the same time. Contacts learn about '
                'the new device automatically.',
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 12),
              Builder(builder: (ctx) {
                final s = ctx.watch<SyncService>();
                final line = s.lastResult ??
                    (s.pendingDeviceName != null
                        ? 'Linking ${s.pendingDeviceName}…'
                        : 'Waiting for the other device…');
                return Text(line, style: const TextStyle(fontSize: 12));
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              sync.stopLinking();
              Navigator.pop(ctx);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDevicesDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Consumer<IdentityService>(
        builder: (ctx, identity, _) {
          final list = identity.deviceList;
          final devices = list?.devices ?? const [];
          return AlertDialog(
            title: const Text('Your Devices'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Each device has its own encryption key, certified by your '
                    'identity. Removing one stops contacts sending to it. It '
                    'keeps what it already has, and it still holds your identity '
                    'key — if a device was stolen rather than retired, you need '
                    'a new identity, not just a shorter list.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (devices.isEmpty)
                    const Text('Only this device.'),
                  for (final d in devices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(d.deviceId == identity.deviceId
                          ? Icons.smartphone
                          : Icons.devices_other),
                      title: Text(d.name ?? 'Device ${d.deviceId.substring(0, 6)}'),
                      subtitle: Text(
                        '${d.deviceId == identity.deviceId ? 'This device · ' : ''}'
                        'added ${DateTime.fromMillisecondsSinceEpoch(d.createdAtMs).toLocal().toString().substring(0, 10)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'rename') {
                            final name = await _askText(ctx, 'Name this device', d.name ?? '');
                            if (name != null && name.isNotEmpty) {
                              await identity.renameDevice(d.deviceId, name);
                            }
                          } else if (action == 'revoke') {
                            final sure = await showDialog<bool>(
                              context: ctx,
                              builder: (c) => AlertDialog(
                                title: const Text('Remove this device?'),
                                content: const Text(
                                    'Contacts stop sending to it. It keeps everything '
                                    'it already has and still holds your identity key.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
                                ],
                              ),
                            );
                            if (sure != true) return;
                            try {
                              await identity.revokeDevice(d.deviceId);
                              messenger.showSnackBar(const SnackBar(
                                  content: Text('Device removed; contacts are being told')));
                            } catch (e) {
                              messenger.showSnackBar(SnackBar(content: Text('$e')));
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'rename', child: Text('Rename')),
                          if (d.deviceId != identity.deviceId)
                            const PopupMenuItem(value: 'revoke', child: Text('Remove')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            ],
          );
        },
      ),
    );
  }

  Future<String?> _askText(BuildContext context, String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(c, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _showCloneDialog(BuildContext context, SyncService sync) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join From Another Device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the pairing code shown on your first device. This device '
              'becomes one of that identity\'s devices, with its own key, and '
              'replaces any identity already here.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              // A base64 code is case-sensitive; the default keyboard
              // capitalised its first letter and "corrected" the rest.
              textCapitalization: TextCapitalization.none,
              keyboardType: TextInputType.visiblePassword,
              decoration: const InputDecoration(labelText: 'Pairing code'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Join'),
          ),
        ],
      ),
    );

    if (code == null || code.isEmpty) return;
    final problem = await sync.startSecondaryLinking(code,
        deviceName: 'New ${Theme.of(context).platform.name} device');
    messenger.showSnackBar(SnackBar(
      content: Text(problem ??
          'Waiting for the other device… keep both apps open.'),
    ));
  }

  Future<void> _showExportDialog(
      BuildContext context, IdentityService identity) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    final passphrase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export Identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your identity is encrypted with this passphrase before it '
              'leaves the app. Anyone holding both the export and the '
              'passphrase becomes you, and it cannot be revoked — choose '
              'something long, and do not reuse it.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Passphrase'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Export'),
          ),
        ],
      ),
    );

    if (passphrase == null) return;
    if (passphrase.length < 12) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Use at least 12 characters — this protects your identity'),
      ));
      return;
    }

    try {
      final vault = await identity.exportIdentity(passphrase);
      await Clipboard.setData(ClipboardData(text: vault));
      messenger.showSnackBar(const SnackBar(
        content: Text('Encrypted identity copied to the clipboard'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  String _notificationSummary(NotificationService n, WakeService w) {
    if (!n.enabled) return 'Off';
    if (!w.enabled) return 'While the app is open only';
    if (w.registeredCount > 0) {
      return 'On · ${w.provider.name} wakes this device';
    }
    if (w.started) return 'On · waiting for ${w.provider.name}';
    return 'On · background delivery not set up';
  }

  Future<void> _showNotificationsDialog(BuildContext context) async {
    final wake = context.read<WakeService>();
    final messenger = ScaffoldMessenger.of(context);
    final provider = wake.provider;
    final available = await provider.isAvailable;
    final reason = available ? null : await provider.unavailableReason;
    final distributors = provider is UnifiedPushWakeProvider
        ? await provider.distributors()
        : const <String>[];
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final n = ctx.watch<NotificationService>();
          final w = ctx.watch<WakeService>();
          return AlertDialog(
            title: const Text('Notifications'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Every notification is built on this phone from content '
                    'that was decrypted here. To be woken while the app is '
                    'closed, the relay knocks on a push endpoint — the knock '
                    'carries nothing, and whoever runs that endpoint learns '
                    'only that this phone was woken, and when.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: n.enabled,
                    title: const Text('Show notifications',
                        style: TextStyle(fontSize: 14)),
                    onChanged: (v) async {
                      if (v) {
                        final ok = await n.requestPermission();
                        if (!ok) {
                          messenger.showSnackBar(const SnackBar(
                              content: Text(
                                  'Notifications were not allowed by the system')));
                        }
                      }
                      await n.setEnabled(v);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: n.preview,
                    title: const Text('Show message text',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                        'Off shows only who it is from, not what they said',
                        style: TextStyle(fontSize: 11)),
                    onChanged: n.enabled ? (v) => n.setPreview(v) : null,
                  ),
                  for (final kind in InboundKind.values)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: n.allows(kind),
                      title: Text(_kindLabel(kind),
                          style: const TextStyle(fontSize: 13)),
                      onChanged: n.enabled
                          ? (v) => n.setAllowed(kind, v ?? false)
                          : null,
                    ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: w.enabled,
                    title: const Text('Wake for new mail',
                        style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      available
                          ? (w.registeredCount > 0
                              ? '${provider.name}: ${w.registeredCount} mailbox(es) '
                                  'registered with the relay'
                              : '${provider.name} is available')
                          : (reason ?? 'Not available on this device'),
                      style: const TextStyle(fontSize: 11),
                    ),
                    onChanged: available ? (v) => w.setEnabled(v) : null,
                  ),
                  if (provider is UnifiedPushWakeProvider &&
                      distributors.length > 1) ...[
                    const SizedBox(height: 4),
                    const Text('Distributor', style: TextStyle(fontSize: 12)),
                    for (final d in distributors)
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: d,
                        groupValue: provider.distributor,
                        title: Text(d, style: const TextStyle(fontSize: 12)),
                        onChanged: (v) async {
                          if (v == null) return;
                          await provider.useDistributor(v);
                          await w.start();
                          setDialogState(() {});
                        },
                      ),
                  ],
                  if (w.lastError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'The relay refused the wake endpoint: ${w.lastError}',
                      style: TextStyle(
                          fontSize: 11, color: Theme.of(ctx).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close')),
            ],
          );
        },
      ),
    );
  }

  static String _kindLabel(InboundKind kind) {
    switch (kind) {
      case InboundKind.chat:
        return 'Direct messages';
      case InboundKind.sphereChat:
        return 'Sphere chats';
      case InboundKind.post:
        return 'New posts and stories';
      case InboundKind.comment:
        return 'Comments on your posts';
      case InboundKind.contactRequest:
        return 'Contact requests';
      case InboundKind.call:
        return 'Calls';
      case InboundKind.security:
        return 'Security notices (keys changed, new devices)';
    }
  }

  Future<void> _showCallServersDialog(
      BuildContext context, CallConfig config) async {
    final controller = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Call Servers'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A STUN server learns your public IP. A TURN server relays '
                  'the whole call when a direct connection is not possible, so '
                  'it sees both IPs and the timing and volume of the media — '
                  'the audio and video stay encrypted, the metadata does not.\n\n'
                  'By default both come from whoever runs your relay: it issues '
                  'short-lived TURN credentials for its own server, so no '
                  'unaffiliated third party is in the path. If your relay has '
                  'no TURN set up, calls fall back to public STUN only and '
                  'connect only over a direct path.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: config.turnEnabled,
                  title: const Text('Allow TURN relay',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    'Off means calls only connect over a direct path — more '
                    'private, but fails behind some networks.',
                    style: TextStyle(fontSize: 11),
                  ),
                  onChanged: (v) async {
                    await config.setTurnEnabled(v);
                    setDialogState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: config.relayOnlyEnabled,
                  title: const Text('Relay every call through TURN',
                      style: TextStyle(fontSize: 14)),
                  subtitle: const Text(
                    'A test setting: the call takes the TURN path even when a '
                    'direct one exists, which is how to check that TURN works. '
                    'Costs the relay operator bandwidth; needs TURN allowed.',
                    style: TextStyle(fontSize: 11),
                  ),
                  onChanged: config.turnEnabled
                      ? (v) async {
                          await config.setRelayOnly(v);
                          setDialogState(() {});
                        }
                      : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  maxLines: 4,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Custom servers (optional)',
                    hintText: 'turn:turn.example.org:3478,user,secret',
                    helperText: 'One per line, replaces the defaults',
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await config.resetToDefault();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Reset'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
            ElevatedButton(
              onPressed: () async {
                final error = await config.setCustom(controller.text);
                if (!ctx.mounted) return;
                if (error != null) {
                  messenger.showSnackBar(SnackBar(content: Text(error)));
                  return;
                }
                Navigator.pop(ctx);
                messenger.showSnackBar(const SnackBar(
                    content: Text('Call servers updated for the next call')));
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBlockedDialog(BuildContext context) async {
    final service = context.read<ContactService>();
    final blocked = service.contacts.where((c) => c.blocked).toList();

    if (blocked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nobody is blocked')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Blocked Contacts'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: blocked
                .map((contact) => ListTile(
                      dense: true,
                      title: Text(contact.displayName),
                      trailing: TextButton(
                        onPressed: () async {
                          await service.toggleBlock(contact.publicKey);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: const Text('Unblock'),
                      ),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _showStorageDialog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final dir = await getApplicationDocumentsDirectory();
    final cache = Directory('${dir.path}/media');

    var bytes = 0;
    var files = 0;
    if (cache.existsSync()) {
      for (final entity in cache.listSync()) {
        if (entity is File) {
          bytes += entity.lengthSync();
          files++;
        }
      }
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cached Media'),
        content: Text(
          files == 0
              ? 'No downloaded media is cached.'
              : '$files file(s), ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB.\n\n'
                  'Clearing frees space. Anything still available on the relay '
                  'will be downloaded again when you open it; media older than '
                  'the relay retention window is gone for good.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          if (files > 0)
            TextButton(
              onPressed: () async {
                try {
                  await cache.delete(recursive: true);
                  messenger.showSnackBar(
                      const SnackBar(content: Text('Cached media cleared')));
                } catch (e) {
                  messenger
                      .showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Clear', style: TextStyle(color: Colors.red)),
            ),
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
    final controller = TextEditingController();
    final passphrase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The backup holds ${BackupService.coverageSummary} With a '
              'passphrase it is encrypted; leave it empty and the file '
              'contains your private key in readable form, so anyone who gets '
              'it becomes you.\n\n'
              'A forgotten passphrase cannot be reset — the backup is simply '
              'unrecoverable.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                helperText: 'Leave empty for an unencrypted backup',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (passphrase == null) return;
    if (passphrase.isNotEmpty && passphrase.length < 12) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Use at least 12 characters, or leave it empty'),
        ));
      }
      return;
    }

    try {
      final filePath = await backupService.createBackup(
        passphrase: passphrase.isEmpty ? null : passphrase,
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

  Future<String?> _askPassphrase(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup passphrase'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Passphrase'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Restore')),
        ],
      ),
    );
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
                      // An encrypted backup needs its passphrase; asking for
                      // one here was the missing step, so a backup made with
                      // one could never be restored from this list.
                      String? passphrase;
                      try {
                        final raw = await File(backups[i].path).readAsString();
                        if (Vault.looksLikeVault(raw)) {
                          if (!context.mounted) return;
                          passphrase = await _askPassphrase(context);
                          if (passphrase == null) return;
                        }
                      } catch (_) {
                        // Let restoreBackup report the unreadable file.
                      }
                      try {
                        await backupService.restoreBackup(backups[i].path,
                            passphrase: passphrase);
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
              'Pre-alpha build. Messages, posts, albums and calls are '
              'encrypted, local data is encrypted at rest, and backups and '
              'recovery work — but none of this has been independently audited, '
              'and it has run between real phones only once. Do not rely '
              'on it if being read would put you at risk.',
              style: TextStyle(color: cs.onErrorContainer, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

