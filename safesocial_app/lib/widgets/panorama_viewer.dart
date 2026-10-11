import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A full 360° picture, panned around by dragging.
///
/// The picture is equirectangular: its width is the whole horizon, so the
/// view scrolls sideways without end and is drawn twice at the seam. Up and
/// down are clamped to the picture. Pinch zooms in a little. It is a
/// cylinder, not a sphere: the poles are not corrected, which is the honest
/// amount of projection for a viewer with no 3D stack.
class PanoramaViewer extends StatefulWidget {
  final String path;

  const PanoramaViewer({super.key, required this.path});

  @override
  State<PanoramaViewer> createState() => _PanoramaViewerState();
}

class _PanoramaViewerState extends State<PanoramaViewer> {
  ui.Image? _image;
  double _x = 0; // horizontal offset in image pixels, wraps
  double _y = 0; // vertical offset in image pixels, clamped
  double _zoom = 1.0;
  double _zoomAtStart = 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final image = await decodeImageFromList(bytes);
      if (mounted) setState(() => _image = image);
    } catch (_) {
      // Shown as a plain image by the caller's fallback.
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (context, box) {
      // Scale so the picture's height fills the view at zoom 1.
      final scale = box.maxHeight / image.height * _zoom;
      final drawnWidth = image.width * scale;
      final drawnHeight = image.height * scale;
      final maxY = (drawnHeight - box.maxHeight).clamp(0.0, double.infinity);
      return GestureDetector(
        onScaleStart: (_) => _zoomAtStart = _zoom,
        onScaleUpdate: (d) => setState(() {
          _zoom = (_zoomAtStart * d.scale).clamp(1.0, 3.0);
          _x = (_x - d.focalPointDelta.dx) % drawnWidth;
          _y = (_y - d.focalPointDelta.dy).clamp(0.0, maxY);
        }),
        child: ClipRect(
          child: CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _PanoramaPainter(image, scale: scale, x: _x, y: _y),
          ),
        ),
      );
    });
  }
}

class _PanoramaPainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final double x;
  final double y;

  _PanoramaPainter(this.image, {required this.scale, required this.x, required this.y});

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width * scale;
    final h = image.height * scale;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    // Draw at the current offset and once more to the right, so the seam is
    // always covered while the offset wraps.
    for (final shift in [-w, 0.0, w]) {
      final left = -x + shift;
      if (left > size.width || left + w < 0) continue;
      canvas.drawImageRect(image, src, Rect.fromLTWH(left, -y, w, h), paint);
    }
  }

  @override
  bool shouldRepaint(_PanoramaPainter old) =>
      old.image != image || old.scale != scale || old.x != x || old.y != y;
}
