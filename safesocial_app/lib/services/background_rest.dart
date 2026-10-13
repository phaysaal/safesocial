import 'dart:async';

import 'package:flutter/foundation.dart';

import 'debug_log_service.dart';

/// Lets the hub socket go while the app is off the screen, so the relay
/// knocks instead of talking to a socket the phone can no longer hear.
///
/// Seen on the Samsung (Android 16) on 13 October 2026: a minute after the
/// app left the screen the system cut its network, every lookup failing, yet
/// the socket it had opened looked alive to the relay for far longer. A
/// message for the phone went to that socket, the relay counted a listener
/// and never knocked, and the phone showed nothing until the app was opened.
/// With the socket closed on purpose the relay has nobody to deliver to, so
/// it knocks, the distributor wakes the app for a sync window, and the window
/// ends with the socket released again. The headless wake already worked this
/// way; this is the same rule for a UI that is merely off screen.
///
/// A call in progress keeps the socket: the signalling rides on it and the
/// platform keeps the network up for a call.
class BackgroundRest {
  BackgroundRest({
    required this.rest,
    required this.wake,
    this.busy,
    this.grace = const Duration(seconds: 15),
  });

  /// Close the socket and stop reconnecting.
  final void Function() rest;

  /// Bring the socket back.
  final void Function() wake;

  /// True while the socket must stay (a call).
  final bool Function()? busy;

  /// How long the app may be off screen before the socket goes: long enough
  /// for a send made on the way out, short enough to beat the network cut.
  final Duration grace;

  bool _foreground = true;
  bool _resting = false;
  Timer? _timer;

  /// Whether the UI is on screen, as last told.
  bool get foreground => _foreground;

  /// The socket was let go by this and not yet brought back.
  @visibleForTesting
  bool get resting => _resting;

  /// The UI is on screen again.
  void onForeground() {
    _foreground = true;
    _timer?.cancel();
    _timer = null;
    if (_resting) {
      _resting = false;
      DebugLogService().info('Relay', 'Back on screen; the hub returns');
      wake();
    }
  }

  /// The UI left the screen. The socket goes after [grace].
  void onBackground() {
    _foreground = false;
    if (_resting || _timer != null) return;
    _timer = Timer(grace, _release);
  }

  /// A wake's sync window closed. Off screen, that is the moment to let go
  /// without waiting out the grace again.
  void onWindowClosed() {
    if (_foreground) return;
    _timer?.cancel();
    _timer = null;
    _release();
  }

  void _release() {
    _timer = null;
    if (_foreground) return;
    if (busy?.call() ?? false) {
      _timer = Timer(grace, _release);
      return;
    }
    _resting = true;
    DebugLogService().info(
        'Relay', 'Off screen; the hub rests until a wake or a return');
    rest();
  }
}
