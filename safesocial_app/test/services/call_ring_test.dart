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
}
