import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/media_provenance.dart';
import 'media_thumb.dart';
import 'provenance_badge.dart';

/// Thumbnail preview for a media item in a message, tappable to open the
/// full viewer. Rendering is shared with every other list via [MediaThumb].
///
/// Shows the sender's trust score when the message carries one, and starts
/// blurred when the chat asks for that.
class MediaPreview extends StatelessWidget {
  final String mediaRef;
  final MediaProvenance? provenance;
  final bool blurred;

  const MediaPreview({
    super.key,
    required this.mediaRef,
    this.provenance,
    this.blurred = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    final thumb = GestureDetector(
      onTap: () {
        context.push('/media/view?ref=${Uri.encodeComponent(mediaRef)}');
      },
      child: MediaThumb(ref: mediaRef, width: 120, height: 120, borderRadius: radius),
    );
    final p = provenance;
    final withBadge = p == null
        ? thumb
        : Stack(children: [
            thumb,
            Positioned(right: 4, bottom: 4, child: ProvenanceBadge(provenance: p, compact: true)),
          ]);
    return BlurGate(blurred: blurred, borderRadius: radius, child: withBadge);
  }
}
