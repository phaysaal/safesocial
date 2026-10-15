import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The two things a video renderer must do, in the order they must happen.
///
/// Abstract so the ordering rule can be tested without the platform plugin.
abstract class VideoSink<T> {
  Future<void> initialize();
  set srcObject(T? stream);
  Future<void> dispose();
}

/// Holds a stream for a renderer until the renderer is ready for it.
///
/// `RTCVideoRenderer` throws if a stream is assigned before `initialize()`
/// has completed. On the receiving side of a call the offer, the local
/// stream and the first build all land within the same instant, so the
/// screen used to assign the stream inside `build` before the renderer
/// existed and the whole screen became an error page. This gate remembers
/// the stream that was wanted and applies it once, when it can.
class RendererGate<T> {
  final VideoSink<T> sink;

  bool _ready = false;
  bool _disposed = false;
  T? _wanted;
  T? _attached;
  Object? _initError;

  /// Called once the renderer can draw, so the screen can rebuild.
  void Function()? onReady;

  RendererGate(this.sink);

  bool get isReady => _ready;
  bool get isDisposed => _disposed;

  /// Why the renderer could not start, when it could not.
  Object? get initError => _initError;

  /// What is currently assigned to the sink.
  T? get attached => _attached;

  /// Initialise the sink, then apply whatever stream arrived in the meantime.
  Future<void> start() async {
    try {
      await sink.initialize();
    } catch (e) {
      _initError = e;
      return;
    }
    if (_disposed) return;
    _ready = true;
    _apply();
    onReady?.call();
  }

  /// Ask for [stream] to be shown. Safe at any time, including before
  /// [start] has finished and after [dispose].
  void attach(T? stream) {
    _wanted = stream;
    if (_ready && !_disposed) _apply();
  }

  void _apply() {
    if (identical(_attached, _wanted)) return;
    sink.srcObject = _wanted;
    _attached = _wanted;
  }

  /// Show the same stream again. A renderer takes the stream's first video
  /// track when the stream is assigned, so a track that joins or leaves
  /// later (a camera turned on in a voice call) is not seen until the stream
  /// is assigned afresh.
  void reattach() {
    if (!_ready || _disposed || _wanted == null) return;
    sink.srcObject = null;
    sink.srcObject = _wanted;
    _attached = _wanted;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wanted = null;
    if (!_ready) return; // Nothing was created yet; nothing to release.
    try {
      sink.srcObject = null;
      await sink.dispose();
    } catch (_) {
      // The renderer is going away either way.
    }
  }
}

/// The real renderer behind the gate.
class RtcVideoSink implements VideoSink<MediaStream> {
  final RTCVideoRenderer renderer;
  RtcVideoSink(this.renderer);

  @override
  Future<void> initialize() => renderer.initialize();

  @override
  set srcObject(MediaStream? stream) => renderer.srcObject = stream;

  @override
  Future<void> dispose() => renderer.dispose();
}
