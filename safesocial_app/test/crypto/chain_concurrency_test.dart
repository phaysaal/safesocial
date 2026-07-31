import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/pairwise_session.dart';

/// Found on two emulators: Alice messaged Bob, Bob replied, and Alice logged
///
///   Rejected message from …: No message key for this sequence —
///   already processed or replayed
///
/// Bob's reply never appeared. Advancing the chain is not atomic — a message
/// key and its successor are both awaits — so two overlapping callers read the
/// same chain key and were handed the same index. Two envelopes went out under
/// one sequence number, and the recipient correctly rejected the second.
///
/// A typing signal sent alongside a message is exactly such a pair, which is
/// what made a latent race into a reproducible lost message.
void main() {
  Uint8List seed() => Uint8List.fromList(List.generate(32, (i) => i));

  group('advancing concurrently', () {
    test('never hands out the same index twice', () async {
      final chain = KdfChain(seed());

      final steps = await Future.wait(
          List.generate(50, (_) => chain.next()));

      expect(steps.map((s) => s.index).toSet(), hasLength(50));
    });

    test('never hands out the same key twice', () async {
      // The consequence that matters: two plaintexts under one message key.
      // Survivable here only because the nonce is random per envelope.
      final chain = KdfChain(seed());

      final steps = await Future.wait(
          List.generate(50, (_) => chain.next()));

      final keys = steps.map((s) => String.fromCharCodes(s.key)).toSet();
      expect(keys, hasLength(50));
    });

    test('indices are contiguous from zero', () async {
      final chain = KdfChain(seed());

      final steps = await Future.wait(
          List.generate(20, (_) => chain.next()));

      final indices = steps.map((s) => s.index).toList()..sort();
      expect(indices, List.generate(20, (i) => i));
      expect(chain.index, 20);
    });
  });

  group('receiving concurrently', () {
    test('overlapping lookups each get their own key', () async {
      // What the receiving side does when a burst arrives at once.
      final sender = KdfChain(seed());
      final receiver = KdfChain(seed());

      final sent = <int, Uint8List>{};
      for (var i = 0; i < 10; i++) {
        final step = await sender.next();
        sent[step.index] = step.key;
      }

      // Deliberately out of order, all at once.
      final targets = [7, 2, 9, 0, 5, 1, 8, 3, 6, 4];
      final received =
          await Future.wait(targets.map((t) => receiver.keyFor(t)));

      for (var i = 0; i < targets.length; i++) {
        expect(received[i], isNotNull,
            reason: 'no key for sequence ${targets[i]}');
        expect(received[i], sent[targets[i]]);
      }
    });

    test('a genuine replay is still refused', () async {
      // The check that produced the original symptom must keep working.
      final sender = KdfChain(seed());
      final receiver = KdfChain(seed());

      final step = await sender.next();
      expect(await receiver.keyFor(step.index), step.key);

      expect(await receiver.keyFor(step.index), isNull);
    });
  });
}
