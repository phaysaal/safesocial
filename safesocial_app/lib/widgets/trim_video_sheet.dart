import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/media_service.dart';

/// Choose which part of a clip to send and which frame stands for it.
///
/// Nothing is cut here: the choice is written beside the file and applied
/// when the clip is transcoded for the relay, so the original stays whole
/// until the moment it leaves.
class TrimVideoSheet extends StatefulWidget {
  final String path;
  final Duration duration;

  const TrimVideoSheet({super.key, required this.path, required this.duration});

  /// Shows the sheet; returns true when a choice was saved.
  static Future<bool> show(BuildContext context, String path) async {
    final duration = await MediaService.transcoder.durationOf(path);
    if (duration == null || !context.mounted) return false;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TrimVideoSheet(path: path, duration: duration),
    );
    return saved == true;
  }

  @override
  State<TrimVideoSheet> createState() => _TrimVideoSheetState();
}

class _TrimVideoSheetState extends State<TrimVideoSheet> {
  late RangeValues _range;
  late double _posterAt;
  Uint8List? _frame;
  bool _loadingFrame = false;

  @override
  void initState() {
    super.initState();
    final total = widget.duration.inMilliseconds.toDouble();
    final existing = MediaService.trimFor(widget.path);
    _range = RangeValues(
      (existing?.start.inMilliseconds.toDouble() ?? 0).clamp(0, total),
      ((existing?.end ?? widget.duration).inMilliseconds.toDouble()).clamp(0, total),
    );
    _posterAt = (existing?.posterAt?.inMilliseconds.toDouble() ?? _range.start).clamp(0, total);
    _loadFrame();
  }

  Future<void> _loadFrame() async {
    setState(() => _loadingFrame = true);
    final bytes = await MediaService.transcoder
        .poster(widget.path, at: Duration(milliseconds: _posterAt.round()));
    if (mounted) {
      setState(() {
        _frame = bytes;
        _loadingFrame = false;
      });
    }
  }

  String _fmt(double ms) {
    final d = Duration(milliseconds: ms.round());
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    final t = (d.inMilliseconds % 1000) ~/ 100;
    return '$m:${s.toString().padLeft(2, '0')}.$t';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.duration.inMilliseconds.toDouble();
    final keeps = Duration(milliseconds: (_range.end - _range.start).round());
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Trim and cover frame', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 180,
                  child: _frame == null
                      ? const Center(child: CircularProgressIndicator())
                      : Stack(fit: StackFit.passthrough, children: [
                          Image.memory(_frame!, fit: BoxFit.contain, gaplessPlayback: true),
                          if (_loadingFrame)
                            const Positioned.fill(
                                child: ColoredBox(
                                    color: Colors.black26,
                                    child: Center(child: CircularProgressIndicator()))),
                        ]),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Keep ${_fmt(_range.start)} to ${_fmt(_range.end)}  ·  ${keeps.inSeconds} s',
                style: theme.textTheme.bodySmall),
            RangeSlider(
              values: _range,
              min: 0,
              max: total,
              onChanged: (v) {
                if (v.end - v.start < 1000) return; // keep at least a second
                setState(() {
                  _range = v;
                  _posterAt = _posterAt.clamp(v.start, v.end);
                });
              },
              onChangeEnd: (_) => _loadFrame(),
            ),
            Text('Cover frame at ${_fmt(_posterAt)}', style: theme.textTheme.bodySmall),
            Slider(
              value: _posterAt,
              min: _range.start,
              max: _range.end,
              onChanged: (v) => setState(() => _posterAt = v),
              onChangeEnd: (_) => _loadFrame(),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () async {
                    await MediaService.clearTrim(widget.path);
                    if (context.mounted) Navigator.pop(context, true);
                  },
                  child: const Text('Whole clip'),
                ),
                FilledButton(
                  onPressed: () async {
                    await MediaService.writeTrim(
                      widget.path,
                      VideoTrim(
                        start: Duration(milliseconds: _range.start.round()),
                        end: Duration(milliseconds: _range.end.round()),
                        posterAt: Duration(milliseconds: _posterAt.round()),
                      ),
                    );
                    if (context.mounted) Navigator.pop(context, true);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
