import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';

import '../../services/library_service.dart';
import '../../services/media_service.dart';

/// Crop, rotate, flip, filter, draw on, and put text or stickers on a picked
/// picture.
///
/// Pixel work (crop, rotate, filters) is done with the `image` package on a
/// copy of the file; text, stickers and drawing are laid over the result by
/// Flutter and the whole thing captured, so emoji and real fonts come out
/// right. The edited file replaces the picked one and keeps its origin score,
/// with an "edited in Spheres" note added so the badge stays honest.
class EditImageScreen extends StatefulWidget {
  final String path;

  const EditImageScreen({super.key, required this.path});

  @override
  State<EditImageScreen> createState() => _EditImageScreenState();
}

enum _Filter { none, mono, sepia, warm, cool, fade }

enum _Crop { free, square, fourThree, sixteenNine }

enum _Tool { move, draw }

/// Something placed over the picture: text, an emoji, or a sticker image.
class _Overlay {
  String? text;
  String? stickerPath;
  Offset position; // fractions of the picture
  double scale;

  _Overlay({this.text, this.stickerPath, required this.position, this.scale = 1});
}

class _Stroke {
  final Color color;
  final double width;
  final List<Offset> points; // fractions of the picture

  _Stroke(this.color, this.width, this.points);
}

class _EditImageScreenState extends State<EditImageScreen> {
  final _boundary = GlobalKey();
  img.Image? _original;
  img.Image? _working;
  Uint8List? _preview;
  int _rotation = 0; // quarter turns
  bool _flipped = false;
  _Filter _filter = _Filter.none;
  _Crop _crop = _Crop.free;
  _Tool _tool = _Tool.move;
  final List<_Overlay> _overlays = [];
  final List<_Stroke> _strokes = [];
  Color _penColor = Colors.white;
  double _penWidth = 6;
  bool _busy = true;
  bool _saving = false;

  static const _emoji = [
    '😀', '😂', '🥰', '😎', '🤩', '🥳', '😍', '🤔', '🙌', '👏', '🔥', '❤️', '💙', '💚',
    '⭐', '✨', '🌈', '☀️', '🌙', '🎉', '🎂', '🍕', '☕', '🌸', '🌍', '✈️', '🏖️', '⚽',
    '🎵', '📸', '💯', '✅', '👀', '🫶', '🐶', '🐱',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    _original = decoded;
    await _rebuild();
  }

  /// Apply rotation, flip, crop and filter to a fresh copy of the original.
  Future<void> _rebuild() async {
    final original = _original;
    if (original == null) return;
    setState(() => _busy = true);
    var work = img.Image.from(original);
    if (_rotation != 0) work = img.copyRotate(work, angle: _rotation * 90);
    if (_flipped) work = img.flipHorizontal(work);
    final ratio = switch (_crop) {
      _Crop.free => null,
      _Crop.square => 1.0,
      _Crop.fourThree => 4 / 3,
      _Crop.sixteenNine => 16 / 9,
    };
    if (ratio != null) {
      final w = work.width;
      final h = work.height;
      int cw = w, ch = h;
      if (w / h > ratio) {
        cw = (h * ratio).round();
      } else {
        ch = (w / ratio).round();
      }
      work = img.copyCrop(work, x: (w - cw) ~/ 2, y: (h - ch) ~/ 2, width: cw, height: ch);
    }
    switch (_filter) {
      case _Filter.none:
        break;
      case _Filter.mono:
        work = img.grayscale(work);
      case _Filter.sepia:
        work = img.sepia(work);
      case _Filter.warm:
        work = img.adjustColor(work, saturation: 1.15, gamma: 0.95);
        work = img.colorOffset(work, red: 12, blue: -8);
      case _Filter.cool:
        work = img.adjustColor(work, saturation: 0.95);
        work = img.colorOffset(work, red: -8, blue: 14);
      case _Filter.fade:
        work = img.adjustColor(work, contrast: 0.85, saturation: 0.8, brightness: 1.05);
    }
    _working = work;
    // The preview is a smaller JPEG; the saved file is full size.
    final small = work.width > 1200 ? img.copyResize(work, width: 1200) : work;
    _preview = Uint8List.fromList(img.encodeJpg(small, quality: 85));
    if (mounted) setState(() => _busy = false);
  }

  bool get _hasOverlay => _overlays.isNotEmpty || _strokes.isNotEmpty;

  Future<void> _save() async {
    final work = _working;
    if (work == null) return;
    setState(() => _saving = true);
    try {
      Uint8List out;
      if (!_hasOverlay) {
        out = Uint8List.fromList(img.encodeJpg(work, quality: 90));
      } else {
        // Capture the preview with everything on it, then scale back to the
        // working size so the file keeps its resolution.
        final boundary = _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final shot = await boundary.toImage(pixelRatio: 2);
        final png = await shot.toByteData(format: ui.ImageByteFormat.png);
        final captured = img.decodePng(png!.buffer.asUint8List());
        if (captured == null) throw StateError('Could not capture the edit');
        final sized = img.copyResize(captured, width: work.width, height: work.height);
        out = Uint8List.fromList(img.encodeJpg(sized, quality: 90));
      }
      final replaced = await MediaService.replaceEdited(widget.path, out);
      if (mounted) Navigator.pop(context, replaced);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addText() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Text on the picture'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: 'Words; drag into place, pinch to size'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Add')),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty && mounted) {
      setState(() => _overlays.add(_Overlay(text: result.trim(), position: const Offset(0.5, 0.8))));
    }
  }

  Future<void> _addSticker() async {
    final stickers = context.read<LibraryService>().stickers;
    final choice = await showModalBottomSheet<_Overlay>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stickers.isNotEmpty) ...[
                const Text('Your stickers', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 72,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final s in stickers)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: () => Navigator.pop(
                                ctx, _Overlay(stickerPath: s, position: const Offset(0.5, 0.5))),
                            child: Image.file(File(s), width: 72, height: 72, fit: BoxFit.contain),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              const Text('Emoji', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final e in _emoji)
                    InkWell(
                      onTap: () => Navigator.pop(
                          ctx, _Overlay(text: e, position: const Offset(0.5, 0.5), scale: 2)),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(e, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice != null && mounted) setState(() => _overlays.add(choice));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Edit picture'),
        actions: [
          if (_hasOverlay)
            IconButton(
              tooltip: 'Undo',
              icon: const Icon(Icons.undo),
              onPressed: () => setState(() {
                if (_strokes.isNotEmpty && _tool == _Tool.draw) {
                  _strokes.removeLast();
                } else if (_overlays.isNotEmpty) {
                  _overlays.removeLast();
                } else if (_strokes.isNotEmpty) {
                  _strokes.removeLast();
                }
              }),
            ),
          TextButton(
            onPressed: _busy || _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Use', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _preview == null
                  ? const CircularProgressIndicator()
                  : RepaintBoundary(
                      key: _boundary,
                      child: _Canvas(
                        preview: _preview!,
                        overlays: _overlays,
                        strokes: _strokes,
                        drawing: _tool == _Tool.draw,
                        penColor: _penColor,
                        penWidth: _penWidth,
                        busy: _busy,
                        onChanged: () => setState(() {}),
                      ),
                    ),
            ),
          ),
          // ── Filters, or pen colours while drawing ────────────────
          SizedBox(
            height: 44,
            child: _tool == _Tool.draw
                ? ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final c in [
                        Colors.white, Colors.black, Colors.red, Colors.orange, Colors.yellow,
                        Colors.green, Colors.blue, Colors.purple, Colors.pink,
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8, top: 6),
                          child: InkWell(
                            onTap: () => setState(() => _penColor = c),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: _penColor == c ? cs.primary : Colors.white24, width: 3),
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: SizedBox(
                          width: 140,
                          child: Slider(
                            value: _penWidth,
                            min: 2,
                            max: 24,
                            onChanged: (v) => setState(() => _penWidth = v),
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final f in _Filter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(f.name[0].toUpperCase() + f.name.substring(1)),
                            selected: _filter == f,
                            onSelected: (_) {
                              _filter = f;
                              _rebuild();
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          // ── Tools ────────────────────────────────────────────────
          SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Rotate',
                  color: Colors.white,
                  icon: const Icon(Icons.rotate_right),
                  onPressed: () {
                    _rotation = (_rotation + 1) % 4;
                    _rebuild();
                  },
                ),
                IconButton(
                  tooltip: 'Flip',
                  color: Colors.white,
                  icon: const Icon(Icons.flip),
                  onPressed: () {
                    _flipped = !_flipped;
                    _rebuild();
                  },
                ),
                PopupMenuButton<_Crop>(
                  tooltip: 'Crop',
                  icon: Icon(Icons.crop, color: _crop == _Crop.free ? Colors.white : cs.primary),
                  onSelected: (c) {
                    _crop = c;
                    _rebuild();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: _Crop.free, child: Text('Original')),
                    PopupMenuItem(value: _Crop.square, child: Text('Square')),
                    PopupMenuItem(value: _Crop.fourThree, child: Text('4 : 3')),
                    PopupMenuItem(value: _Crop.sixteenNine, child: Text('16 : 9')),
                  ],
                ),
                IconButton(
                  tooltip: 'Text',
                  color: Colors.white,
                  icon: const Icon(Icons.title),
                  onPressed: _addText,
                ),
                IconButton(
                  tooltip: 'Sticker',
                  color: Colors.white,
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  onPressed: _addSticker,
                ),
                IconButton(
                  tooltip: _tool == _Tool.draw ? 'Stop drawing' : 'Draw',
                  color: _tool == _Tool.draw ? cs.primary : Colors.white,
                  icon: const Icon(Icons.brush_outlined),
                  onPressed: () =>
                      setState(() => _tool = _tool == _Tool.draw ? _Tool.move : _Tool.draw),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture with its overlays and strokes, sized to the picture.
class _Canvas extends StatefulWidget {
  final Uint8List preview;
  final List<_Overlay> overlays;
  final List<_Stroke> strokes;
  final bool drawing;
  final Color penColor;
  final double penWidth;
  final bool busy;
  final VoidCallback onChanged;

  const _Canvas({
    required this.preview,
    required this.overlays,
    required this.strokes,
    required this.drawing,
    required this.penColor,
    required this.penWidth,
    required this.busy,
    required this.onChanged,
  });

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> {
  _Stroke? _current;
  _Overlay? _held;
  double _heldScale = 1;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      return GestureDetector(
        onScaleStart: (d) {
          if (widget.drawing) {
            _current = _Stroke(widget.penColor, widget.penWidth, [_frac(d.localFocalPoint, box)]);
            widget.strokes.add(_current!);
          } else {
            _held = _nearest(d.localFocalPoint, box);
            _heldScale = _held?.scale ?? 1;
          }
        },
        onScaleUpdate: (d) {
          if (widget.drawing) {
            _current?.points.add(_frac(d.localFocalPoint, box));
          } else if (_held != null) {
            final h = _held!;
            h.position = Offset(
              (h.position.dx + d.focalPointDelta.dx / box.maxWidth).clamp(0.02, 0.98),
              (h.position.dy + d.focalPointDelta.dy / box.maxHeight).clamp(0.02, 0.98),
            );
            h.scale = (_heldScale * d.scale).clamp(0.5, 5);
          }
          widget.onChanged();
        },
        onScaleEnd: (_) {
          _current = null;
          _held = null;
        },
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Image.memory(widget.preview, fit: BoxFit.contain, gaplessPlayback: true),
            Positioned.fill(
              child: CustomPaint(painter: _StrokePainter(widget.strokes)),
            ),
            for (final o in widget.overlays)
              Positioned(
                left: o.position.dx * box.maxWidth - 100 * o.scale,
                top: o.position.dy * box.maxHeight - 24 * o.scale,
                child: IgnorePointer(
                  child: SizedBox(
                    width: 200 * o.scale,
                    child: o.stickerPath != null
                        ? Image.file(File(o.stickerPath!), height: 96 * o.scale, fit: BoxFit.contain)
                        : Text(
                            o.text ?? '',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24 * o.scale,
                              fontWeight: FontWeight.w700,
                              shadows: const [Shadow(color: Colors.black, blurRadius: 8)],
                            ),
                          ),
                  ),
                ),
              ),
            if (widget.busy)
              const Positioned.fill(
                  child: ColoredBox(
                      color: Colors.black38, child: Center(child: CircularProgressIndicator()))),
          ],
        ),
      );
    });
  }

  Offset _frac(Offset p, BoxConstraints box) =>
      Offset(p.dx / box.maxWidth, p.dy / box.maxHeight);

  _Overlay? _nearest(Offset p, BoxConstraints box) {
    _Overlay? best;
    var bestD = double.infinity;
    for (final o in widget.overlays) {
      final c = Offset(o.position.dx * box.maxWidth, o.position.dy * box.maxHeight);
      final d = (c - p).distance;
      if (d < bestD && d < 120 * o.scale) {
        best = o;
        bestD = d;
      }
    }
    return best;
  }
}

class _StrokePainter extends CustomPainter {
  final List<_Stroke> strokes;
  _StrokePainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = Offset(s.points[i].dx * size.width, s.points[i].dy * size.height);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (s.points.length == 1) {
        final p = Offset(s.points.first.dx * size.width, s.points.first.dy * size.height);
        canvas.drawCircle(p, s.width / 2, paint..style = PaintingStyle.fill);
      } else {
        canvas.drawPath(path, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_StrokePainter old) => true;
}
