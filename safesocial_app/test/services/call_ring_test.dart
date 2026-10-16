import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/call_service.dart';

void main() {
  final now = DateTime(2026, 10, 11, 11, 33);

  test('a ring sent moments ago rings', () {
    final data = {'type': 'call_offer', 'at': now.subtract(const Duration(seconds: 5)).millisecondsSinceEpoch};
    expect(CallService.isStaleRing(data, now: now), isFalse);
  });

  test('a ring the mailbox replays from a previous session does not', () {
    final data = {'type': 'call_offer', 'at': now.subtract(const Duration(minutes: 13)).millisecondsSinceEpoch};
    expect(CallService.isStaleRing(data, now: now), isTrue);
  });

  test('a ring without a stamp, from an older client, is taken as current', () {
    expect(CallService.isStaleRing({'type': 'call_offer'}, now: now), isFalse);
  });

  group('notes in a call', () {
    test('the other side turning notes on turns them on here and says who began', () {
      final c = CallService();
      expect(c.notesOn, isFalse);
      c.applyNotesSignal('bob-key-0001', {'type': 'call_notes', 'on': true});
      expect(c.notesOn, isTrue);
      expect(c.notesStartedBy, 'bob-key-0001');
      c.applyNotesSignal('bob-key-0001', {'type': 'call_notes', 'on': false});
      expect(c.notesOn, isFalse);
      expect(c.notesStartedBy, isNull);
      // Anything but a plain true is off.
      c.applyNotesSignal('bob-key-0001', {'type': 'call_notes', 'on': 'yes'});
      expect(c.notesOn, isFalse);
    });

    test('the button does nothing outside a call', () async {
      final c = CallService();
      await c.setNotes(true);
      expect(c.notesOn, isFalse);
    });
  });

  group('video in and out of a call', () {
    test('when both sides offer at once, exactly one gives way', () {
      expect(CallService.isPolite('aaa', 'bbb'), isTrue);
      expect(CallService.isPolite('bbb', 'aaa'), isFalse);
      expect(CallService.isPolite('aaa', 'aaa'), isFalse,
          reason: 'our own other device is never deferred to twice');
    });

    test("a signal says whether the sender's picture is on; an older client's is read from the call's kind", () {
      expect(CallService.remoteVideoFrom({'video': true}, fallback: false), isTrue);
      expect(CallService.remoteVideoFrom({'video': false}, fallback: true), isFalse);
      expect(CallService.remoteVideoFrom({'call_type': 'video'}, fallback: true), isTrue);
      expect(CallService.remoteVideoFrom({'video': 'yes'}, fallback: false), isFalse,
          reason: 'anything but a boolean is not a claim');
    });
  });
}
