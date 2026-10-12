import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../crypto/blob.dart';
import '../../models/media_protection.dart';
import '../../services/blob_service.dart';
import '../../services/debug_log_service.dart';
import '../../services/media_service.dart';
import '../../services/screen_guard.dart';
import '../../widgets/protected_veil.dart';

/// Full-screen viewer for protected media; see [MediaProtection].
///
/// The blob is decrypted here, into memory for a picture and into a temporary
/// file that is deleted on the way out for a video (the platform player needs
/// a file). It never touches the media cache. The window is marked secure
/// while this screen is up where the platform allows; where it does not, the
/// screen says so instead of pretending. There are no actions: nothing here
/// can be saved, shared or forwarded.
class ProtectedMediaScreen extends StatefulWidget {
  final String mediaRef;
  final MediaProtection protection;

  /// The viewer's own name, for the watermark.
  final String? viewerName;

  /// Overridable so a test can hand in bytes without a relay.
  static Future<Uint8List?> Function(BlobRef ref)? fetchOverride;

  const ProtectedMediaScreen(
      {super.key, required this.mediaRef, required this.protection, this.viewerName});

  @override
  State<ProtectedMediaScreen> createState() => _ProtectedMediaScreenState();
}

class _ProtectedMediaScreenState extends State<ProtectedMediaScreen>
    with WidgetsBindingObserver {
  final _gate = HoldGate();
  Timer? _timer;

  Uint8List? _bytes;
  double _aspect = 1;
  VideoPlayerController? _video;
  File? _tempVideo;
  String? _error;
  bool _secured = false;
  bool _asked = false;
  String? _captured;

  bool get _isVideo => _video != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ScreenGuard.onCapture = _onCapture;
    unawaited(_secure());
    unawaited(_load());
  }

  Future<void> _secure() async {
    final ok = await ScreenGuard.secure(true);
    DebugLogService().info('Protected', ok ? 'Window secured' : 'Window cannot be secured here');
    if (mounted) setState(() {
      _secured = ok;
      _asked = true;
    });
  }

  Future<void> _load() async {
    final ref = widget.mediaRef;
    final blob = BlobRef.tryDecode(ref);
    try {
      if (blob != null) {
        final fetch = ProtectedMediaScreen.fetchOverride ?? BlobService().download;
        final bytes = await fetch(blob);
        if (bytes == null) {
          _fail('Could not fetch this media. The relay may no longer have it, or you may be offline.');
          return;
        }
        if (blob.isVideo) {
          final dir = Directory('${(await getTemporaryDirectory()).path}/protected');
          if (!dir.existsSync()) await dir.create(recursive: true);
          final file = File('${dir.path}/${const Uuid().v4()}.mp4');
          await file.writeAsBytes(bytes, flush: true);
          _tempVideo = file;
          await _startVideo(file);
        } else {
          await _showImage(bytes);
        }
      } else if (File(ref).existsSync()) {
        // Our own copy, on the device that made it.
        if (MediaService.looksLikeVideo(ref)) {
          await _startVideo(File(ref));
        } else {
          await _showImage(await File(ref).readAsBytes());
        }
      } else {
        _fail('This file is no longer on the device.');
      }
    } catch (e) {
      _fail('Could not open this media: $e');
    }
  }

  Future<void> _showImage(Uint8List bytes) async {
    final decoded = await decodeImageFromList(bytes);
    final aspect = decoded.width / decoded.height;
    decoded.dispose();
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _aspect = aspect;
    });
  }

  Future<void> _startVideo(File file) async {
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    await controller.setLooping(true);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    controller.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() {
      _video = controller;
      _aspect = controller.value.aspectRatio;
    });
  }

  void _fail(String text) {
    if (mounted) setState(() => _error = text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (ScreenGuard.onCapture == _onCapture) ScreenGuard.onCapture = null;
    _timer?.cancel();
    unawaited(ScreenGuard.secure(false));
    _video?.dispose();
    final temp = _tempVideo;
    if (temp != null && temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
    final bytes = _bytes;
    if (bytes != null) unawaited(MemoryImage(bytes).evict());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _hide(reset: true);
  }

  void _onCapture(String kind) {
    _hide(reset: true);
    if (!mounted) return;
    setState(() => _captured = kind == 'recording'
        ? 'Screen recording was noticed; the picture stays hidden while it runs.'
        : 'A screenshot was taken. Protected media hides itself when that happens.');
  }

  // -- The hold ---------------------------------------------------------------

  void _pointerDown(PointerDownEvent e) {
    _gate.down(e.pointer);
    _apply();
  }

  void _pointerUp(int pointer) {
    _gate.up(pointer);
    _apply();
  }

  bool _wasShowing = false;

  void _apply() {
    final showing = _gate.showing;
    if (showing != _wasShowing) {
      _wasShowing = showing;
      DebugLogService().info('Protected', showing ? 'Shown' : 'Hidden');
    }
    if (showing && _timer == null) {
      _timer = Timer(_gate.limit, () {
        _gate.expire();
        _timer = null;
        _apply();
      });
    } else if (!showing) {
      _timer?.cancel();
      _timer = null;
    }
    final v = _video;
    if (v != null && v.value.isInitialized) {
      if (showing && !v.value.isPlaying) v.play();
      if (!showing && v.value.isPlaying) v.pause();
    }
    if (mounted) setState(() {});
  }

  void _hide({bool reset = false}) {
    if (reset) _gate.reset();
    _apply();
  }

  // -- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final me = widget.viewerName;
    final dance = !MediaQuery.disableAnimationsOf(context);
    final showing = _gate.showing;

    Widget body;
    if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(32),
        child: Text(_error!, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70)),
      );
    } else if (_bytes == null && _video == null) {
      body = const CircularProgressIndicator(color: Colors.white);
    } else {
      final content = _isVideo
          ? VideoPlayer(_video!)
          : Image.memory(_bytes!, fit: BoxFit.contain, gaplessPlayback: true);
      body = AspectRatio(
        aspectRatio: _aspect,
        child: ProtectedVeil(
          revealed: showing,
          dance: dance,
          watermark: widget.protection.watermark ? (me ?? '') : null,
          child: content,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline, color: Colors.white, size: 18),
          SizedBox(width: 8),
          Text('Protected', style: TextStyle(color: Colors.white, fontSize: 16)),
        ]),
      ),
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerUp: (e) => _pointerUp(e.pointer),
        onPointerCancel: (e) => _pointerUp(e.pointer),
        child: Column(
          children: [
            Expanded(child: Center(child: body)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Column(children: [
                Text(
                  _captured ?? 'Two fingers on the glass show it, for ten seconds at a time. '
                      'Nothing here can be saved, shared or forwarded.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _captured == null ? Colors.white54 : Colors.orangeAccent, fontSize: 12),
                ),
                if (_asked && !_secured) ...[
                  const SizedBox(height: 6),
                  const Text('Screenshots cannot be blocked on this phone.',
                      key: Key('no-secure-flag'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
