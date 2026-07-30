import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/typing_tracker.dart';

/// Clock is injected everywhere so these assert real elapsed-time behaviour
/// without any of the tests actually waiting.
void main() {
  final t0 = DateTime(2026, 7, 30, 12);
  late TypingTracker tracker;

  setUp(() {
    tracker = TypingTracker(
      ttl: const Duration(seconds: 7),
      throttle: const Duration(seconds: 3),
    );
  });

  group('inbound signals', () {
    test('a signal shows the peer as typing', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      expect(tracker.isTyping('bob', now: t0), isTrue);
    });

    test('an unknown peer is not typing', () {
      expect(tracker.isTyping('nobody', now: t0), isFalse);
    });

    test('an indicator expires on its own', () {
      tracker.noteSignal('bob', stopped: false, now: t0);

      // The whole point: a "stopped" that never arrives — app killed, relay
      // dropped it — must not leave bob typing forever.
      expect(
        tracker.isTyping('bob', now: t0.add(const Duration(seconds: 8))),
        isFalse,
      );
    });

    test('a refresh extends the indicator', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      tracker.noteSignal('bob',
          stopped: false, now: t0.add(const Duration(seconds: 5)));

      expect(
        tracker.isTyping('bob', now: t0.add(const Duration(seconds: 10))),
        isTrue,
      );
    });

    test('a stop clears it immediately', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      tracker.noteSignal('bob',
          stopped: true, now: t0.add(const Duration(seconds: 1)));

      expect(
        tracker.isTyping('bob', now: t0.add(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('peers are tracked separately', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      tracker.noteSignal('carol', stopped: false, now: t0);
      tracker.noteSignal('bob', stopped: true, now: t0);

      expect(tracker.isTyping('bob', now: t0), isFalse);
      expect(tracker.isTyping('carol', now: t0), isTrue);
    });

    test('noteSignal reports only real changes, so redraws are not wasted', () {
      expect(tracker.noteSignal('bob', stopped: false, now: t0), isTrue);

      // Still typing: nothing on screen changes.
      expect(
        tracker.noteSignal('bob',
            stopped: false, now: t0.add(const Duration(seconds: 1))),
        isFalse,
      );

      expect(
        tracker.noteSignal('bob',
            stopped: true, now: t0.add(const Duration(seconds: 1))),
        isTrue,
      );

      // A stop for someone who was not typing changes nothing either.
      expect(tracker.noteSignal('bob', stopped: true, now: t0), isFalse);
    });
  });

  group('outbound throttling', () {
    test('the first keystroke sends', () {
      expect(tracker.shouldSend('bob', stopped: false, now: t0), isTrue);
    });

    test('keystrokes inside the throttle window do not', () {
      tracker.shouldSend('bob', stopped: false, now: t0);

      for (var ms = 100; ms < 3000; ms += 300) {
        expect(
          tracker.shouldSend('bob',
              stopped: false, now: t0.add(Duration(milliseconds: ms))),
          isFalse,
        );
      }
    });

    test('typing past the window sends a refresh', () {
      tracker.shouldSend('bob', stopped: false, now: t0);

      expect(
        tracker.shouldSend('bob',
            stopped: false, now: t0.add(const Duration(seconds: 4))),
        isTrue,
      );
    });

    test('a stop is never throttled', () {
      tracker.shouldSend('bob', stopped: false, now: t0);

      // Swallowing this would make the peer wait out the whole TTL.
      expect(
        tracker.shouldSend('bob',
            stopped: true, now: t0.add(const Duration(milliseconds: 200))),
        isTrue,
      );
    });

    test('a stop with nothing to stop is not sent', () {
      // Clearing an untouched composer should not put traffic on the relay.
      expect(tracker.shouldSend('bob', stopped: true, now: t0), isFalse);
    });

    test('after a stop the next keystroke sends again', () {
      tracker.shouldSend('bob', stopped: false, now: t0);
      tracker.shouldSend('bob', stopped: true, now: t0);

      expect(
        tracker.shouldSend('bob',
            stopped: false, now: t0.add(const Duration(milliseconds: 100))),
        isTrue,
      );
    });

    test('throttling is per peer', () {
      tracker.shouldSend('bob', stopped: false, now: t0);
      expect(tracker.shouldSend('carol', stopped: false, now: t0), isTrue);
    });
  });

  group('sweeping', () {
    test('sweeping an empty tracker reports no change', () {
      expect(tracker.sweep(now: t0), isFalse);
    });

    test('sweeping drops only expired indicators', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      tracker.noteSignal('carol',
          stopped: false, now: t0.add(const Duration(seconds: 6)));

      expect(tracker.sweep(now: t0.add(const Duration(seconds: 8))), isTrue);
      expect(tracker.isTyping('carol', now: t0.add(const Duration(seconds: 8))),
          isTrue);
    });

    test('sweeping with nothing expired reports no change', () {
      tracker.noteSignal('bob', stopped: false, now: t0);
      expect(tracker.sweep(now: t0.add(const Duration(seconds: 1))), isFalse);
    });
  });

  test('clearing forgets peers and our own send history', () {
    tracker.noteSignal('bob', stopped: false, now: t0);
    tracker.shouldSend('carol', stopped: false, now: t0);

    tracker.clear();

    expect(tracker.isTyping('bob', now: t0), isFalse);
    // And the throttle is reset, so re-enabling behaves like a fresh start.
    expect(tracker.shouldSend('carol', stopped: false, now: t0), isTrue);
  });
}
