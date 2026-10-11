import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../models/media_provenance.dart';

/// A small pill with a shield and the 0–10 trust score, laid over a thumbnail.
/// Tapping it opens [showProvenanceSheet], which says why and carries the
/// disclaimer.
class ProvenanceBadge extends StatelessWidget {
  final MediaProvenance provenance;
  final bool compact;

  const ProvenanceBadge({super.key, required this.provenance, this.compact = false});

  /// Green for camera bands, amber for unknown, red for the bottom bands.
  static Color colorFor(int score) {
    if (score >= 8) return const Color(0xFF2E7D32);
    if (score >= 6) return const Color(0xFF558B2F);
    if (score >= 4) return const Color(0xFFEF6C00);
    return const Color(0xFFC62828);
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(provenance.score);
    return Semantics(
      button: true,
      label: 'Trust ${provenance.score} of 10, ${provenance.band}',
      child: GestureDetector(
        onTap: () => showProvenanceSheet(context, provenance),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: compact ? 2 : 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.verified_user_outlined, size: compact ? 12 : 14, color: color),
            const SizedBox(width: 3),
            Text(
              '${provenance.score}',
              style: TextStyle(
                color: Colors.white,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The explanation behind a trust score, in words rendered on this device.
Future<void> showProvenanceSheet(BuildContext context, MediaProvenance p) {
  final theme = Theme.of(context);
  final color = ProvenanceBadge.colorFor(p.score);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Text('${p.score}',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Trust ${p.score} of 10', style: theme.textTheme.titleMedium),
                  Text(p.band, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Text(p.note, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 14),
            Text(
              MediaProvenance.disclaimer,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '10 is a photo taken from inside Spheres. 8 to 9 is a camera photo with no sign '
              'of editing. 6 to 7 was edited after it was taken. 4 to 5 carries no origin '
              'data. 1 to 3 looks like a screenshot, a download or a generator\'s output. '
              '0 is marked by its maker as AI-generated.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Blurs [child] until tapped once, when a chat or sphere asks for its media
/// to be hidden. The first tap reveals; the next tap reaches the child.
class BlurGate extends StatefulWidget {
  final bool blurred;
  final Widget child;
  final BorderRadius? borderRadius;

  const BlurGate({super.key, required this.blurred, required this.child, this.borderRadius});

  @override
  State<BlurGate> createState() => _BlurGateState();
}

class _BlurGateState extends State<BlurGate> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.blurred || _revealed) return widget.child;
    Widget veil = Stack(
      fit: StackFit.passthrough,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18, tileMode: TileMode.decal),
          child: widget.child,
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _revealed = true),
            child: Container(
              color: Colors.black.withValues(alpha: 0.25),
              alignment: Alignment.center,
              child: const Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.visibility_off_outlined, color: Colors.white, size: 26),
                SizedBox(height: 4),
                Text('Tap to show',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ],
    );
    if (widget.borderRadius != null) {
      veil = ClipRRect(borderRadius: widget.borderRadius!, child: veil);
    }
    return veil;
  }
}
