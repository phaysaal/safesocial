import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/background_rest.dart';

/// Found on the Samsung on 13 October 2026: off screen, the system cut the
/// app's network while its socket still looked alive to the relay, so the
/// relay delivered to that socket and never knocked. These pin the rule that
/// an app off screen lets its socket go, so the relay has nobody to talk to
/// and wakes the phone instead.
void main() {
  late int rested;
  late int woken;
  late bool inCall;

  BackgroundRest build() => BackgroundRest(
        rest: () => rested++,
        wake: () => woken++,
        busy: () => inCall,
        grace: const Duration(seconds: 15),
      );

  setUp(() {
    rested = 0;
    woken = 0;
    inCall = false;
  });

  test('off screen for the grace period the hub rests; back on screen it returns',
      () {
    fakeAsync((async) {
      final r = build();
      r.onBackground();
      async.elapse(const Duration(seconds: 14));
      expect(rested, 0, reason: 'a send made on the way out still has its socket');

      async.elapse(const Duration(seconds: 2));
      expect(rested, 1);
      expect(r.resting, isTrue);

      r.onForeground();
      expect(woken, 1);
      expect(r.resting, isFalse);
    });
  });

  test('a quick return rests nothing and wakes nothing', () {
    fakeAsync((async) {
      final r = build();
      r.onBackground();
      async.elapse(const Duration(seconds: 5));
      r.onForeground();
      async.elapse(const Duration(minutes: 1));

      expect(rested, 0);
      expect(woken, 0);
    });
  });

  test('a call in progress keeps the socket, and the question is asked again',
      () {
    fakeAsync((async) {
      final r = build();
      inCall = true;
      r.onBackground();
      async.elapse(const Duration(seconds: 16));
      expect(rested, 0, reason: 'the signalling rides on the socket');

      inCall = false;
      async.elapse(const Duration(seconds: 15));
      expect(rested, 1);
    });
  });

  test("a wake's window closing off screen rests at once", () {
    fakeAsync((async) {
      final r = build();
      r.onBackground();
      r.onWindowClosed();
      expect(rested, 1);

      async.elapse(const Duration(seconds: 30));
      expect(rested, 1, reason: 'the grace timer was dropped');
    });
  });

  test("a wake's window closing on screen changes nothing", () {
    fakeAsync((async) {
      final r = build();
      r.onWindowClosed();
      async.elapse(const Duration(seconds: 30));

      expect(rested, 0);
    });
  });

  test('a second background notice while already resting does not rest twice',
      () {
    fakeAsync((async) {
      final r = build();
      r.onBackground();
      async.elapse(const Duration(seconds: 16));
      r.onBackground();
      async.elapse(const Duration(seconds: 16));

      expect(rested, 1);
    });
  });
}
