import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/identity_service.dart';
import '../../services/debug_log_service.dart';

/// Compact scrolling log panel shown during Veilid initialization.
class _InitLogPanel extends StatefulWidget {
  const _InitLogPanel();

  @override
  State<_InitLogPanel> createState() => _InitLogPanelState();
}

class _InitLogPanelState extends State<_InitLogPanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: DebugLogService(),
      builder: (context, _) {
        final logs = DebugLogService().logs;
        _scrollToBottom();
        return Container(
          height: 140,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
          ),
          padding: const EdgeInsets.all(8),
          child: logs.isEmpty
              ? Center(
                  child: Text('Waiting for logs…',
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.4),
                          fontSize: 11,
                          fontFamily: 'monospace')))
              : ListView.builder(
                  controller: _scroll,
                  itemCount: logs.length,
                  itemBuilder: (context, i) {
                    final e = logs[i];
                    final color = switch (e.level) {
                      LogLevel.error => Colors.red.shade300,
                      LogLevel.warning => Colors.orange.shade300,
                      LogLevel.success => Colors.green.shade300,
                      LogLevel.info => Colors.grey.shade400,
                    };
                    return Text(
                      '${e.timeStr} [${e.tag}] ${e.message}',
                      style: TextStyle(
                          color: color, fontSize: 10, fontFamily: 'monospace'),
                    );
                  },
                ),
        );
      },
    );
  }
}

/// Onboarding screen for new users to create their cryptographic identity.
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
      await context.read<IdentityService>().createIdentity(name);
      if (mounted) {
        context.go('/');
      }
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
                  // Fix Issue #10: Validation logic
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
                const _InitLogPanel(),
                const SizedBox(height: 12),

                ListenableBuilder(
                  listenable: context.watch<IdentityService>().veilidService,
                  builder: (context, _) {
                    final vs = context.read<IdentityService>().veilidService;

                    if (vs.isFailed) {
                      return Column(
                        children: [
                          Text(
                            vs.error ?? 'Backend failed to start',
                            style: TextStyle(color: cs.error, fontSize: 12),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton(
                            onPressed: () async {
                              await context.read<IdentityService>().veilidService.retryInitialize();
                            },
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(18),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text(
                              'Retry',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (vs.isProtectedStoreError) ...[
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: () async {
                                await context.read<IdentityService>().veilidService.clearStateAndRetry();
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(16),
                                side: BorderSide(color: cs.error),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: Text(
                                'Clear Corrupted Data & Retry',
                                style: TextStyle(fontSize: 14, color: cs.error),
                              ),
                            ),
                          ],
                        ],
                      );
                    }

                    return ElevatedButton(
                      onPressed: (_isCreating || !vs.isInitialized) ? null : _handleOnboarding,
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
                          : Text(
                              vs.isInitialized ? 'Start Networking' : 'Initializing Backend…',
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () {
                    // TODO: Implement "Import existing identity"
                  },
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
