import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/screens/call/renderer_gate.dart';

/// Behaves like the platform renderer: a stream assigned before initialise
/// has completed is an error, which is exactly what took the receiving side
/// of the first real call down.
class _StrictSink implements VideoSink<String> {
  final Completer<void> _init = Completer<void>();
  bool initialised = false;
  bool disposed = false;
  final assigned = <String?>[];

  void finishInit() => _init.complete();
  void failInit(Object e) => _init.completeError(e);

  @override
  Future<void> initialize() async {
    await _init.future;
    initialised = true;
  }

  @override
  set srcObject(String? stream) {
    if (!initialised) throw StateError('Call initialize before setting the stream');
    if (disposed) throw StateError('disposed');
    assigned.add(stream);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test('a stream that arrives before the renderer is ready waits for it', () async {
    final sink = _StrictSink();
    final gate = RendererGate<String>(sink);
    var readyCalls = 0;
    gate.onReady = () => readyCalls++;

    final started = gate.start();
    gate.attach('local-stream'); // the receiving side: stream before renderer
    expect(sink.assigned, isEmpty, reason: 'nothing may touch the sink yet');
    expect(gate.isReady, isFalse);

    sink.finishInit();
    await started;

    expect(gate.isReady, isTrue);
    expect(sink.assigned, ['local-stream']);
    expect(readyCalls, 1);
  });

  test('the same stream is not reassigned, a new one replaces it', () async {
    final sink = _StrictSink()..finishInit();
    final gate = RendererGate<String>(sink);
    await gate.start();

    gate.attach('a');
    gate.attach('a');
    gate.attach('b');
    gate.attach(null);
    expect(sink.assigned, ['a', 'b', null]);
    expect(gate.attached, isNull);
  });

  test('disposing while initialise is still pending never touches the sink',
      () async {
    final sink = _StrictSink();
    final gate = RendererGate<String>(sink);
    final started = gate.start();
    gate.attach('late');
    await gate.dispose();
    sink.finishInit();
    await started;

    expect(gate.isReady, isFalse);
    expect(sink.assigned, isEmpty);
    expect(sink.disposed, isFalse, reason: 'nothing was created to release');
  });

  test('a renderer that fails to initialise reports it and stays unready',
      () async {
    final sink = _StrictSink();
    final gate = RendererGate<String>(sink);
    final started = gate.start();
    sink.failInit(StateError('no GL context'));
    await started;

    expect(gate.isReady, isFalse);
    expect(gate.initError, isA<StateError>());
    gate.attach('x'); // must not throw
    expect(sink.assigned, isEmpty);
  });

  test('dispose releases a ready renderer and clears its stream first', () async {
    final sink = _StrictSink()..finishInit();
    final gate = RendererGate<String>(sink);
    await gate.start();
    gate.attach('a');
    await gate.dispose();
    expect(sink.assigned, ['a', null]);
    expect(sink.disposed, isTrue);
    expect(gate.isDisposed, isTrue);
  });
}
