import 'package:flutter/material.dart';

import '../models/look.dart';
import 'looked.dart';

/// The presets as chips and, behind Adjust, the ten sliders. The one set of
/// controls for a look, in the editor before sending and in the sheet after.
class LookControls extends StatefulWidget {
  final Look look;
  final ValueChanged<Look> onChanged;

  /// On black (the editor) the labels are light.
  final bool onDark;

  /// The true-skin correction for this picture, when the picture could be
  /// read; the chip is not offered otherwise.
  final Look? trueSkin;

  const LookControls({super.key, required this.look, required this.onChanged, this.onDark = false, this.trueSkin});

  @override
  State<LookControls> createState() => _LookControlsState();
}

enum _Adjust { exposure, temperature, tint, contrast, highlights, shadows, saturation, vibrance, vignette, grain }

class _LookControlsState extends State<LookControls> {
  bool _adjusting = false;

  static String _label(_Adjust a) => switch (a) {
        _Adjust.exposure => 'Exposure',
        _Adjust.temperature => 'Warmth',
        _Adjust.tint => 'Tint',
        _Adjust.contrast => 'Contrast',
        _Adjust.highlights => 'Highlights',
        _Adjust.shadows => 'Shadows',
        _Adjust.saturation => 'Saturation',
        _Adjust.vibrance => 'Vibrance',
        _Adjust.vignette => 'Vignette',
        _Adjust.grain => 'Grain',
      };

  double _value(Look l, _Adjust a) => switch (a) {
        _Adjust.exposure => l.exposure,
        _Adjust.temperature => l.temperature,
        _Adjust.tint => l.tint,
        _Adjust.contrast => l.contrast,
        _Adjust.highlights => l.highlights,
        _Adjust.shadows => l.shadows,
        _Adjust.saturation => l.saturation,
        _Adjust.vibrance => l.vibrance,
        _Adjust.vignette => l.vignette,
        _Adjust.grain => l.grain,
      };

  /// A moved slider makes the look the person's own: the preset name goes.
  Look _set(Look l, _Adjust a, double v) => switch (a) {
        _Adjust.exposure => l.copyWith(exposure: v, clearPreset: true),
        _Adjust.temperature => l.copyWith(temperature: v, clearPreset: true),
        _Adjust.tint => l.copyWith(tint: v, clearPreset: true),
        _Adjust.contrast => l.copyWith(contrast: v, clearPreset: true),
        _Adjust.highlights => l.copyWith(highlights: v, clearPreset: true),
        _Adjust.shadows => l.copyWith(shadows: v, clearPreset: true),
        _Adjust.saturation => l.copyWith(saturation: v, clearPreset: true),
        _Adjust.vibrance => l.copyWith(vibrance: v, clearPreset: true),
        _Adjust.vignette => l.copyWith(vignette: v, clearPreset: true),
        _Adjust.grain => l.copyWith(grain: v, clearPreset: true),
      };

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    final faint = widget.onDark ? Colors.white70 : Theme.of(context).colorScheme.onSurfaceVariant;
    final fainter = widget.onDark ? Colors.white38 : Theme.of(context).colorScheme.outline;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('None'),
                  selected: look.isNone,
                  onSelected: (_) => widget.onChanged(Look.none),
                ),
              ),
              if (widget.trueSkin != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    avatar: const Icon(Icons.face_retouching_natural, size: 16),
                    label: const Text('True skin'),
                    tooltip: 'White balance and light from this picture, so skin reads as it does in life',
                    selected: look.preset == 'True skin',
                    onSelected: (_) => widget.onChanged(widget.trueSkin!),
                  ),
                ),
              for (final p in Look.presets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(p.preset!),
                    selected: look.preset == p.preset,
                    onSelected: (_) => widget.onChanged(p),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  avatar: const Icon(Icons.tune, size: 16),
                  label: const Text('Adjust'),
                  selected: _adjusting,
                  onSelected: (v) => setState(() => _adjusting = v),
                ),
              ),
            ],
          ),
        ),
        if (_adjusting)
          SizedBox(
            height: 112,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final a in _Adjust.values)
                  SizedBox(
                    width: 150,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_label(a), style: TextStyle(color: faint, fontSize: 11)),
                        Slider(
                          value: _value(look, a),
                          min: a == _Adjust.exposure ? -2 : (a == _Adjust.vignette || a == _Adjust.grain ? 0 : -1),
                          max: a == _Adjust.exposure ? 2 : 1,
                          onChanged: (v) => widget.onChanged(_set(look, a, v)),
                        ),
                        Text(_value(look, a).toStringAsFixed(2), style: TextStyle(color: fainter, fontSize: 10)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Change the look of a picture already sent or posted. Returns the look to
/// set, [Look.none] to remove it, or null to leave it.
Future<Look?> showLookSheet(BuildContext context, {required Widget preview, required Look initial, Look? trueSkin}) {
  return showModalBottomSheet<Look>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      var look = initial;
      return StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text('Change the look', style: Theme.of(ctx).textTheme.titleMedium),
                      const Spacer(),
                      Text(
                        'Numbers, not pixels: nothing is re-sent',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 220,
                  child: Center(child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Looked(look: look, child: preview))),
                ),
                const SizedBox(height: 8),
                LookControls(look: look, trueSkin: trueSkin, onChanged: (l) => setState(() => look = l)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      TextButton(onPressed: () => Navigator.pop(ctx, Look.none), child: const Text('Remove the look')),
                      const Spacer(),
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, look), child: const Text('Apply')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
