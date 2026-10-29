import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/identity_service.dart';
import '../services/terms.dart';

/// Before anything can be posted, the person agrees to the terms. New
/// identities agree at onboarding; an identity made before the terms existed
/// meets this screen once.
class TermsGate extends StatefulWidget {
  final Widget child;
  const TermsGate({super.key, required this.child});

  @override
  State<TermsGate> createState() => _TermsGateState();
}

class _TermsGateState extends State<TermsGate> {
  bool? _accepted;

  @override
  void initState() {
    super.initState();
    Terms.accepted().then((v) {
      if (mounted) setState(() => _accepted = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final onboarded = context.watch<IdentityService>().isOnboarded;
    if (!onboarded || _accepted != false) return widget.child;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Text('Before you go on', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(Terms.summary),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => launchUrl(Uri.parse(Terms.url), mode: LaunchMode.externalApplication),
                child: const Text('Read the terms of use'),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    await Terms.accept();
                    if (mounted) setState(() => _accepted = true);
                  },
                  child: const Text('I agree'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
