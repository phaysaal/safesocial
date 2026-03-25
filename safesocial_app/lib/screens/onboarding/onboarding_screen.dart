import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/identity_service.dart';
import '../../widgets/avatar.dart';

/// Multi-step onboarding flow styled like Facebook/Instagram sign-up.
/// Hides all crypto complexity — presents as "Create your profile".
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _isCreating = false;
  int _step = 0; // 0 = welcome, 1 = profile form

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _createIdentity() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isCreating = true);

    try {
      await context.read<IdentityService>().createIdentity(
            _displayNameController.text.trim(),
            _bioController.text.trim(),
          );
      if (mounted) context.go('/');
    } catch (e, stack) {
      debugPrint('[Onboarding] Identity creation failed: $e\n$stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Something went wrong. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: _step == 0
            ? _buildWelcome(theme, cs)
            : _buildProfileForm(theme, cs),
      ),
    );
  }

  // ── Step 0: Welcome ────────────────────────────────────────────────────────

  Widget _buildWelcome(ThemeData theme, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          const Spacer(flex: 2),

          // Logo
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.people_alt_rounded,
              size: 52,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 24),

          Text(
            'SafeSocial',
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w800,
              fontSize: 32,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Connect with friends and family privately. No ads, no tracking, no data collection.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),

          const SizedBox(height: 48),

          // Feature highlights
          const _FeatureRow(
            icon: Icons.lock_outline,
            title: 'Private by design',
            subtitle: 'Messages are encrypted end-to-end',
          ),
          const SizedBox(height: 16),
          const _FeatureRow(
            icon: Icons.cloud_off_outlined,
            title: 'No servers',
            subtitle: 'Your data stays on your device',
          ),
          const SizedBox(height: 16),
          const _FeatureRow(
            icon: Icons.fingerprint,
            title: 'No sign-up hassle',
            subtitle: 'Just pick a name and you\'re in',
          ),

          const Spacer(flex: 3),

          // CTA
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () => setState(() => _step = 1),
              child: const Text('Get Started'),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your data never leaves your device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Step 1: Profile form ───────────────────────────────────────────────────

  Widget _buildProfileForm(ThemeData theme, ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Back button
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _step = 0),
              ),
            ),

            const SizedBox(height: 16),

            Text(
              'Create your profile',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This is how friends will see you on SafeSocial.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 32),

            // Avatar preview
            Center(
              child: Stack(
                children: [
                  UserAvatar(
                    displayName: _displayNameController.text.isNotEmpty
                        ? _displayNameController.text
                        : '?',
                    size: AvatarSize.large,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: cs.surface,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.camera_alt,
                        size: 16,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add photo later',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),

            const SizedBox(height: 32),

            // Name field
            TextFormField(
              controller: _displayNameController,
              decoration: const InputDecoration(
                labelText: 'Your name',
                hintText: 'How friends will see you',
                prefixIcon: Icon(Icons.person_outline),
              ),
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter your name';
                }
                if (value.trim().length < 2) {
                  return 'Name must be at least 2 characters';
                }
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),

            const SizedBox(height: 16),

            // Bio field
            TextFormField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Bio (optional)',
                hintText: 'A little about yourself',
                prefixIcon: Icon(Icons.edit_outlined),
                alignLabelWithHint: true,
              ),
              maxLines: 3,
              maxLength: 200,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SizedBox(height: 32),

            // Continue button
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _isCreating ? null : _createIdentity,
                child: _isCreating
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Feature row widget ──────────────────────────────────────────────────────

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: cs.primary, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
