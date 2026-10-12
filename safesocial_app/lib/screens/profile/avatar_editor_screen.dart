import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/avatar_spec.dart';
import '../../models/media_provenance.dart';
import '../../services/identity_service.dart';
import '../../services/library_service.dart';
import '../../services/media_service.dart';
import '../../services/relay_service.dart';
import '../../services/secure_store.dart';
import '../../widgets/avatar_painter.dart';

/// Draw yourself: a cartoon avatar that becomes the profile picture, and a
/// set of stickers wearing expressions. Drawn on the device; the picture
/// travels to contacts like any profile picture.
class AvatarEditorScreen extends StatefulWidget {
  const AvatarEditorScreen({super.key});

  static const specKey = 'spheres_avatar_v1';

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  AvatarSpec _spec = const AvatarSpec();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    SecureStore.instance.getString(AvatarEditorScreen.specKey).then((raw) {
      if (raw == null || !mounted) return;
      try {
        setState(() => _spec = AvatarSpec.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {}
    });
  }

  static MediaProvenance get _drawn => const MediaProvenance(
        score: 7,
        source: 'app',
        signals: [ProvenanceSignal.editedBySoftware],
        tool: 'Spheres',
      );

  Future<void> _save({required bool stickers}) async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SecureStore.instance.setString(AvatarEditorScreen.specKey, jsonEncode(_spec.toJson()));
      final png = await AvatarPainter.renderPng(_spec);
      final path = await MediaService.storePickedImage(png, provenance: _drawn);
      final identity = context.read<IdentityService>();
      await identity.updateAvatar(path);
      if (!mounted) return;
      await identity.publishProfileToRelay(context.read<RelayService>());
      if (stickers) {
        final library = context.read<LibraryService>();
        for (final e in AvatarExpression.values.where((e) => e != AvatarExpression.plain)) {
          final bytes = await AvatarPainter.renderPng(_spec, size: 384, expression: e);
          final p = await MediaService.storePickedImage(bytes, provenance: _drawn);
          await library.addSticker(p);
        }
      }
      messenger.showSnackBar(SnackBar(content: Text(stickers ? 'Picture set and six stickers added' : 'Picture set')));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _row(String label, int count, int value, List<String>? names, void Function(int) set, {List<Color>? colors}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (var i = 0; i < count; i++)
            colors != null
                ? InkWell(
                    onTap: () => set(i),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colors[i],
                        shape: BoxShape.circle,
                        border: Border.all(color: value == i ? theme.colorScheme.primary : Colors.transparent, width: 3),
                      ),
                    ),
                  )
                : ChoiceChip(label: Text(names![i]), selected: value == i, onSelected: (_) => set(i)),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Draw yourself')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ClipOval(
              child: SizedBox(
                width: 160,
                height: 160,
                child: CustomPaint(painter: AvatarPainter(_spec)),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _row('Skin', AvatarSpec.skins, _spec.skin, null, (i) => setState(() => _spec = _spec.copyWith(skin: i)), colors: AvatarPainter.skinColors),
                _row('Hair', AvatarSpec.hairs, _spec.hair, AvatarPainter.hairNames, (i) => setState(() => _spec = _spec.copyWith(hair: i))),
                _row('Hair colour', AvatarSpec.hairColors, _spec.hairColor, null, (i) => setState(() => _spec = _spec.copyWith(hairColor: i)), colors: AvatarPainter.hairColors),
                _row('Eyes', AvatarSpec.eyeStyles, _spec.eyes, AvatarPainter.eyeNames, (i) => setState(() => _spec = _spec.copyWith(eyes: i))),
                _row('Mouth', AvatarSpec.mouths, _spec.mouth, AvatarPainter.mouthNames, (i) => setState(() => _spec = _spec.copyWith(mouth: i))),
                _row('Glasses', AvatarSpec.glassesStyles, _spec.glasses, AvatarPainter.glassesNames, (i) => setState(() => _spec = _spec.copyWith(glasses: i))),
                _row('Extra', AvatarSpec.extras, _spec.extra, AvatarPainter.extraNames, (i) => setState(() => _spec = _spec.copyWith(extra: i))),
                _row('Background', AvatarSpec.backgrounds, _spec.background, null, (i) => setState(() => _spec = _spec.copyWith(background: i)), colors: AvatarPainter.backgrounds),
                const SizedBox(height: 8),
                Text('Stickers wearing this face:', style: Theme.of(context).textTheme.labelLarge),
                SizedBox(
                  height: 64,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final e in AvatarExpression.values.where((e) => e != AvatarExpression.plain))
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(width: 56, height: 56, child: CustomPaint(painter: AvatarPainter(_spec, expression: e))),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : () => _save(stickers: false),
                  icon: const Icon(Icons.face_outlined),
                  label: const Text('Use as my picture'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _saving ? null : () => _save(stickers: true),
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  label: const Text('Use as my picture and make stickers'),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
