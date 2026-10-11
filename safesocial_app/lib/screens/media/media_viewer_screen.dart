import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

import '../../crypto/blob.dart';
import 'package:provider/provider.dart';

import '../../services/library_service.dart';
import '../../services/media_service.dart';
import '../../widgets/media_thumb.dart';
import '../feed/compose_screen.dart';

/// Full-screen viewer for one piece of media.
///
/// Takes any reference the app holds: a local image or video path, or a
/// [BlobRef] that has not been fetched yet, which it fetches and decrypts
/// here. Images zoom; video plays with a scrubber.
///
/// Two actions, both defined by the sphere model:
///
///  * **Share** re-posts the media into a sphere through the composer. There
///    is no other audience to share to.
///  * **Save** writes a copy to the device gallery, after saying plainly that
///    the copy leaves the encrypted store.
class MediaViewerScreen extends StatefulWidget {
  final String? mediaRef;

  const MediaViewerScreen({super.key, this.mediaRef});

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  /// The resolved local file, once we have one.
  String? _path;
  bool _resolving = false;
  String? _error;

  VideoPlayerController? _video;
  bool _busy = false;

  bool get _isVideo => _path != null && MediaService.looksLikeVideo(_path!);

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final ref = widget.mediaRef;
    if (ref == null || ref.isEmpty) {
      setState(() => _error = 'No media to display');
      return;
    }

    String? path;
    if (BlobRef.looksLikeRef(ref)) {
      setState(() {
        _resolving = true;
        _error = null;
      });
      path = await MediaService.decodeAndSaveImage(ref);
      if (!mounted) return;
      if (path == null) {
        setState(() {
          _resolving = false;
          _error = 'Could not fetch this media. The relay may no longer have '
              'it, or you may be offline.';
        });
        return;
      }
    } else if (File(ref).existsSync()) {
      path = ref;
    } else {
      setState(() => _error = 'This file is no longer on the device.');
      return;
    }

    setState(() {
      _path = path;
      _resolving = false;
    });

    if (_isVideo) await _startVideo(path);
  }

  Future<void> _startVideo(String path) async {
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(false);
      await controller.play();
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() => _error = 'This video could not be played: $e');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    controller.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => _video = controller);
  }

  void _togglePlayback() {
    final v = _video;
    if (v == null) return;
    if (v.value.isPlaying) {
      v.pause();
    } else {
      if (v.value.position >= v.value.duration) v.seekTo(Duration.zero);
      v.play();
    }
  }

  // -- Actions ----------------------------------------------------------------

  Future<void> _share() async {
    final path = _path;
    if (path == null) return;
    _video?.pause();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComposeScreen(initialMedia: [path]),
      ),
    );
  }

  Future<void> _save() async {
    final path = _path;
    if (path == null || _busy) return;
    _video?.pause();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save to gallery?'),
        content: const Text(
          'A copy goes into the phone\'s photo library, outside Spheres\' '
          'encrypted storage. Any app with photo access can read it there, '
          'and deleting it from Spheres later will not remove that copy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save copy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          messenger.showSnackBar(const SnackBar(
            content: Text('Spheres was not allowed to add to the gallery.'),
          ));
          return;
        }
      }
      if (_isVideo) {
        await Gal.putVideo(path, album: 'Spheres');
      } else {
        await Gal.putImage(path, album: 'Spheres');
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved to the gallery')),
      );
    } on GalException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save: ${e.type.message}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ready = _path != null && _error == null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: ready && !_busy ? _share : null,
            tooltip: 'Share into a sphere',
          ),
          if (ready && !_isVideo)
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined),
              tooltip: 'Save as sticker',
              onPressed: () async {
                await context.read<LibraryService>().addSticker(_path!);
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Added to your stickers')));
                }
              },
            ),
          IconButton(
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_outlined),
            onPressed: ready && !_busy ? _save : null,
            tooltip: 'Save to gallery',
          ),
        ],
      ),
      body: Center(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) return _message(context, error, retry: _resolve);

    if (_resolving || _path == null) {
      final ref = widget.mediaRef;
      return Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (ref != null)
            MediaThumb(ref: ref, fit: BoxFit.contain, showPlayBadge: false),
          Container(color: Colors.black45),
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      );
    }

    if (_isVideo) return _videoBody();

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Image.file(File(_path!), fit: BoxFit.contain),
    );
  }

  Widget _videoBody() {
    final v = _video;
    if (v == null || !v.value.isInitialized) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    final ended = v.value.position >= v.value.duration &&
        v.value.duration > Duration.zero;

    return GestureDetector(
      onTap: _togglePlayback,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: v.value.aspectRatio,
            child: VideoPlayer(v),
          ),
          if (!v.value.isPlaying)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(
                ended ? Icons.replay : Icons.play_arrow,
                color: Colors.white,
                size: 48,
              ),
            ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoProgressIndicator(
                  v,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(v.value.position),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Text(_fmt(v.value.duration),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _message(BuildContext context, String text, {VoidCallback? retry}) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 64, color: Colors.white38),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
          if (retry != null && widget.mediaRef != null &&
              BlobRef.looksLikeRef(widget.mediaRef!)) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Try again', style: TextStyle(color: Colors.white)),
            ),
          ],
        ],
      ),
    );
  }
}
