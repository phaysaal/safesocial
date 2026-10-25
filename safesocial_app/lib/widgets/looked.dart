import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/look.dart';

/// Draws [child] with a [Look]: the colour matrix in one pass, then a
/// vignette and grain over it. A look with nothing in it returns the child
/// untouched, with no extra layer at all.
class Looked extends StatelessWidget {
  final Look look;
  final Widget child;
  const Looked({super.key, required this.look, required this.child});

  @override
  Widget build(BuildContext context) {
    if (look.isNone) return child;
    Widget out = child;
    if (look.hasColour) {
      out = ColorFiltered(colorFilter: ColorFilter.matrix(look.matrix()), child: out);
    }
    if (look.vignette == 0 && look.grain == 0) return out;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        out,
        if (look.vignette > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.9,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6 * look.vignette)],
                    stops: const [0.55, 1.0],
                  ),
                ),
              ),
            ),
          ),
        if (look.grain > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _GrainPainter(look.grain)),
            ),
          ),
      ],
    );
  }
}

/// A fixed field of faint dots: the same grain every frame, so nothing
/// shimmers.
class _GrainPainter extends CustomPainter {
  final double amount;
  const _GrainPainter(this.amount);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final count = (size.width * size.height / 60).clamp(200, 6000).toInt();
    final light = Paint()..color = Colors.white.withValues(alpha: 0.18 * amount);
    final dark = Paint()..color = Colors.black.withValues(alpha: 0.18 * amount);
    for (var i = 0; i < count; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1.2, 1.2), i.isEven ? light : dark);
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.amount != amount;
}
