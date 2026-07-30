/// The bookkeeping behind typing indicators, kept apart from the transport.
///
/// Two rules make the indicator behave when the network does not:
///
///  * outbound signals are throttled, so a fast typist sends a few per minute
///    rather than one per keystroke;
///  * inbound signals expire on their own, so a "stopped" that never arrives —
///    the app was killed, the relay dropped it — cannot leave someone shown as
///    typing forever.
class TypingTracker {
  TypingTracker({
    this.ttl = const Duration(seconds: 7),
    this.throttle = const Duration(seconds: 3),
  });

  /// How long an inbound signal counts for without a refresh. Comfortably
  /// longer than [throttle], or a steady typist would flicker.
  final Duration ttl;

  /// Minimum gap between our own outbound signals for one peer.
  final Duration throttle;

  final Map<String, DateTime> _peerLastSignal = {};
  final Map<String, DateTime> _selfLastSent = {};

  /// Record that [peerKey] signalled. Returns true if this changes what the UI
  /// would show, so the caller only rebuilds when it matters.
  bool noteSignal(String peerKey, {required bool stopped, DateTime? now}) {
    final at = now ?? DateTime.now();
    final wasTyping = isTyping(peerKey, now: at);

    if (stopped) {
      _peerLastSignal.remove(peerKey);
    } else {
      _peerLastSignal[peerKey] = at;
    }

    return wasTyping != isTyping(peerKey, now: at);
  }

  bool isTyping(String peerKey, {DateTime? now}) {
    final last = _peerLastSignal[peerKey];
    if (last == null) return false;
    return (now ?? DateTime.now()).difference(last) < ttl;
  }

  /// Whether we should put a signal on the wire for [peerKey] right now.
  ///
  /// A stop always goes out: it is the one that ends the indicator, and
  /// swallowing it would leave the peer waiting out the whole [ttl].
  bool shouldSend(String peerKey, {required bool stopped, DateTime? now}) {
    final at = now ?? DateTime.now();

    if (stopped) {
      // Nothing to stop if we never started.
      if (_selfLastSent.remove(peerKey) == null) return false;
      return true;
    }

    final last = _selfLastSent[peerKey];
    if (last != null && at.difference(last) < throttle) return false;
    _selfLastSent[peerKey] = at;
    return true;
  }

  /// Drop indicators that have aged out. Returns true if any did, since expiry
  /// is time-based and needs something to trigger the redraw.
  bool sweep({DateTime? now}) {
    if (_peerLastSignal.isEmpty) return false;
    final at = now ?? DateTime.now();
    final before = _peerLastSignal.length;
    _peerLastSignal.removeWhere((_, last) => at.difference(last) >= ttl);
    return _peerLastSignal.length != before;
  }

  /// Forget everything — used when indicators are switched off, so nothing is
  /// left to show if they are switched back on.
  void clear() {
    _peerLastSignal.clear();
    _selfLastSent.clear();
  }
}
