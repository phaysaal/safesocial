import 'package:flutter/material.dart';

/// Screen size breakpoints.
const double kTabletBreakpoint = 600;
const double kDesktopBreakpoint = 1024;

bool isTablet(BuildContext context) =>
    MediaQuery.of(context).size.shortestSide >= kTabletBreakpoint;

bool isDesktop(BuildContext context) =>
    MediaQuery.of(context).size.width >= kDesktopBreakpoint;

/// Responsive widget that shows different layouts for phone vs tablet.
class ResponsiveLayout extends StatelessWidget {
  final Widget phone;
  final Widget? tablet;

  const ResponsiveLayout({
    super.key,
    required this.phone,
    this.tablet,
  });

  @override
  Widget build(BuildContext context) {
    if (tablet != null && isTablet(context)) {
      return tablet!;
    }
    return phone;
  }
}

/// Master-detail layout for tablets — list on left, detail on right.
class MasterDetailLayout extends StatelessWidget {
  final Widget master;
  final Widget? detail;
  final double masterWidth;

  const MasterDetailLayout({
    super.key,
    required this.master,
    this.detail,
    this.masterWidth = 380,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        SizedBox(
          width: masterWidth,
          child: master,
        ),
        VerticalDivider(width: 1, color: cs.outline),
        Expanded(
          child: detail ??
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.3)),
                    const SizedBox(height: 16),
                    Text(
                      'Select a conversation',
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
        ),
      ],
    );
  }
}
