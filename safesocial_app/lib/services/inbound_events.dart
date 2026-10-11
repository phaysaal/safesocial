import 'dart:async';

/// What kind of thing arrived.
enum InboundKind { chat, sphereChat, post, comment, reaction, contactRequest, call, security }

/// Something that arrived from someone else and might deserve the user's
/// attention.
///
/// Services emit these after they have verified, decrypted and stored the
/// item. Nothing here is trusted beyond that: [title] and [body] are what the
/// notification shows, and [route] is where a tap goes.
class InboundEvent {
  final InboundKind kind;

  /// Stable id, so a repeat (a message fetched twice) notifies once.
  final String id;

  /// Who it is from — a display name, never a key.
  final String title;

  /// The content, if the user allows previews; shown as a generic line
  /// otherwise.
  final String body;

  /// GoRouter location to open on tap.
  final String route;

  /// Groups notifications: one per conversation or sphere.
  final String thread;

  /// The identity key of whoever caused it, when there is one, so a muted
  /// or snoozed contact can be kept quiet.
  final String? from;

  const InboundEvent({
    required this.kind,
    required this.id,
    required this.title,
    required this.body,
    required this.route,
    required this.thread,
    this.from,
  });

  @override
  String toString() => 'InboundEvent(${kind.name} $id from "$title")';
}

/// Process-wide bus for [InboundEvent]s.
///
/// A bus rather than wiring every service to the notification service
/// directly: the services do not know whether they are running under the UI,
/// under a push wake with no UI, or in a test, and should not have to.
class InboundEvents {
  InboundEvents._();

  static final StreamController<InboundEvent> _controller =
      StreamController<InboundEvent>.broadcast();

  static Stream<InboundEvent> get stream => _controller.stream;

  static void emit(InboundEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }
}
