import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The rule for showing protected media.
///
/// Two fingers on the glass show it; the moment one lifts it hides. A hold
/// lasts at most [limit]; when the time is up it hides, and every finger has
/// to lift before another hold counts. Pure, so the rule can be tested
/// without a screen; the widget owns the clock.
class HoldGate {
  HoldGate({this.fingers = 2, this.limit = const Duration(seconds: 10)});

  final int fingers;
  final Duration limit;
  final Set<int> _pointers = {};
  bool _expired = false;

  bool get showing => _pointers.length >= fingers && !_expired;
  int get pointers => _pointers.length;

  void down(int pointer) => _pointers.add(pointer);

  void up(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty) _expired = false;
  }

  /// The hold has lasted [limit].
  void expire() => _expired = true;

  /// The app went to the background, or the platform saw a capture: hide,
  /// and forget the fingers, which the platform will not report lifting.
  void reset() {
    _pointers.clear();
    _expired = false;
  }
}

/// Which stripes are sharp this frame: a CRT-style sweep.
///
/// The picture is cut into [bands] × [groups] horizontal stripes. Each frame,
/// every [bands]th stripe is sharp and the rest blurred, and the sharp set
/// steps down one stripe per frame, so the whole picture is covered every
/// [bands] frames. At 60 Hz with three bands that is a 20 Hz cycle, past the
/// point where the eye fuses a change that keeps the brightness the same, and
/// a camera's single frame still gets a third of the picture in thin stripes.
/// Random tiles were tried first and read as a boiling shimmer; one wide band
/// was better but visibly rolled; several interleaved stripes move in
/// smaller steps and read as a fine, fast scan. Every frame has the same
/// sharp area, so the brightness never changes from frame to frame; that is
/// what matters for photosensitive epilepsy.
class ScanBand {
  static List<Rect> sharp(int frame, Size size, {int bands = 3, int groups = 3}) {
    final stripes = bands * groups;
    final h = size.height / stripes;
    final phase = frame % bands;
    return [
      for (var k = 0; k < stripes; k++)
        if (k % bands == phase) Rect.fromLTWH(0, k * h, size.width, h),
    ];
  }
}

/// A small lock laid over a list thumbnail of protected media.
class ProtectedMark extends StatelessWidget {
  const ProtectedMark({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
        child: const Icon(Icons.lock_outline, color: Colors.white, size: 14),
      );
}

/// Blurs [child] except while [revealed]; while revealed, with [dance] on,
/// a third of the picture is sharp each frame, in stripes that step down
/// like a CRT scan ([ScanBand]), and the rest blurred. The eye integrates a sharp picture; a camera
/// pointed at the screen gets a single frame, which is a blurred picture with
/// one sharp band.
/// With [dance] off (reduce motion), revealed means plain.
///
/// [watermark], when given, is drawn across the middle while revealed.
class ProtectedVeil extends StatefulWidget {
  final Widget child;
  final bool revealed;
  final bool dance;
  final String? watermark;
  final String hint;

  const ProtectedVeil({
    super.key,
    required this.child,
    required this.revealed,
    this.dance = true,
    this.watermark,
    this.hint = 'Hold with two fingers to see it',
  });

  @override
  State<ProtectedVeil> createState() => _ProtectedVeilState();
}

class _ProtectedVeilState extends State<ProtectedVeil> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frame = 0;

  bool get _dancing => widget.revealed && widget.dance;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() => _frame++));
    if (_dancing) _ticker.start();
  }

  @override
  void didUpdateWidget(ProtectedVeil old) {
    super.didUpdateWidget(old);
    if (_dancing && !_ticker.isActive) _ticker.start();
    if (!_dancing && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth.isFinite ? c.maxWidth : 300.0;
      final h = c.maxHeight.isFinite ? c.maxHeight : 300.0;
      final blurred = Path()..fillType = PathFillType.evenOdd;
      blurred.addRect(Rect.fromLTWH(0, 0, w, h));
      if (widget.revealed && widget.dance) {
        // Cut the sharp stripes out of the blur.
        for (final r in ScanBand.sharp(_frame, Size(w, h))) {
          blurred.addRect(r);
        }
      }

      final showVeil = !widget.revealed || widget.dance;
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (showVeil)
            Positioned.fill(
              child: ClipPath(
                clipper: _PathClipper(blurred),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16, tileMode: TileMode.clamp),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          if (!widget.revealed)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.25),
                  alignment: Alignment.center,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.touch_app_outlined, color: Colors.white, size: 36),
                    const SizedBox(height: 8),
                    Text(widget.hint,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600,
                            shadows: [Shadow(color: Colors.black, blurRadius: 6)])),
                  ]),
                ),
              ),
            ),
          if (widget.revealed && (widget.watermark?.isNotEmpty ?? false))
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Transform.rotate(
                    angle: -0.45,
                    child: Text(
                      widget.watermark!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                        shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

class _PathClipper extends CustomClipper<Path> {
  final Path path;
  const _PathClipper(this.path);
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_PathClipper old) => true;
}
