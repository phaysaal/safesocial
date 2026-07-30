import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app_wiring.dart';
import '../../crypto/session_manager.dart';
import '../../services/album_service.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/outbox_service.dart';
import '../../services/sphere_service.dart';
import '../../services/relay_service.dart';
import '../../services/debug_log_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleOnboarding() async {
    // Fix Issue #10: Validate input
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final name = _nameController.text.trim();
    setState(() => _isCreating = true);

    try {
      final idService = context.read<IdentityService>();
      await idService.createIdentity(name);

      if (!mounted) return;
      await _wire();

      if (mounted) {
        final relay = context.read<RelayService>();
        await idService.publishProfileToRelay(relay);
      }
      if (mounted) context.go('/');
    } catch (e) {
      DebugLogService().error('Onboarding', 'Failed to create identity: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  /// Connect the new identity to every service.
  ///
  /// Without this the first session after onboarding has no identity wired
  /// anywhere: no handshakes, no relay, no crypto sessions, and a crash on
  /// creating a group. It used to take an app restart to recover.
  Future<void> _wire() async {
    await wireIdentity(
      identityService: context.read<IdentityService>(),
      sessionManager: context.read<SessionManager>(),
      contactService: context.read<ContactService>(),
      chatService: context.read<ChatService>(),
      outboxService: context.read<OutboxService>(),
      callService: context.read<CallService>(),
      feedService: context.read<FeedService>(),
      albumService: context.read<AlbumService>(),
      sphereService: context.read<SphereService>(),
    );
  }

  Future<void> _showImportDialog(BuildContext context) async {
    final blobController = TextEditingController();
    final passphraseController = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import Identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste your exported identity below. If it was encrypted, enter '
              'the passphrase you chose.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: blobController,
              decoration: const InputDecoration(labelText: 'Backup data'),
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passphraseController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                helperText: 'Leave empty if the export was not encrypted',
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
            onPressed: () async {
              final blob = blobController.text.trim();
              if (blob.isEmpty) return;
              Navigator.pop(ctx);
              try {
                final idService = context.read<IdentityService>();
                final pass = passphraseController.text;
                final ok = await idService.importIdentity(
                  blob,
                  passphrase: pass.isEmpty ? null : pass,
                );
                if (!mounted) return;
                if (ok) {
                  await _wire();
                  if (!mounted) return;
                  final relay = context.read<RelayService>();
                  await idService.publishProfileToRelay(relay);
                  if (mounted) context.go('/');
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Import failed — the backup data is not a valid identity')),
                  );
                }
              } catch (e) {
                DebugLogService().error('Onboarding', 'Import failed: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Import failed: $e')),
                  );
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
    blobController.dispose();
    passphraseController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Center(
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 120,
                    height: 120,
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  'Welcome to Spheres',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Your data. Your network. Your rules.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'e.g. Alice',
                    prefixIcon: const Icon(Icons.person_outline),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  textCapitalization: TextCapitalization.words,
                  autofocus: true,
                  onFieldSubmitted: (_) => _handleOnboarding(),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a name';
                    }
                    if (value.trim().length < 2) {
                      return 'Name is too short (min 2 chars)';
                    }
                    if (value.trim().length > 30) {
                      return 'Name is too long (max 30 chars)';
                    }
                    if (!RegExp(r'^[a-zA-Z0-9 _-]+$').hasMatch(value)) {
                      return 'Only letters, numbers, spaces, and -_ allowed';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _isCreating ? null : _handleOnboarding,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: _isCreating
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Text(
                          'Start Networking',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => _showImportDialog(context),
                  child: Text(
                    'Import existing identity',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
