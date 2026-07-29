import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/outbox_service.dart';

/// The outbox is what turns "the socket was down so your message vanished"
/// into "your message is queued". These tests pin that behaviour, especially
/// across an app restart.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('a message sent while offline stays pending, not lost', () async {
    final outbox = OutboxService()..send = (_, __) async => false;

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');

    expect(outbox.pendingCount, 1);
    expect(outbox.stateOf('m1'), OutboxState.pending);
  });

  test('a message is marked sent once the relay accepts it', () async {
    final outbox = OutboxService()..send = (_, __) async => true;

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');

    expect(outbox.stateOf('m1'), OutboxState.sent);
    expect(outbox.pendingCount, 0);
  });

  test('a queued message is retried when the peer reconnects', () async {
    var online = false;
    final sent = <String>[];
    final outbox = OutboxService()
      ..send = (peer, payload) async {
        if (!online) return false;
        sent.add(payload);
        return true;
      };

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');
    expect(outbox.stateOf('m1'), OutboxState.pending);
    expect(sent, isEmpty);

    online = true;
    await outbox.flush(onlyPeer: 'bob');

    expect(sent, ['sealed']);
    expect(outbox.stateOf('m1'), OutboxState.sent);
  });

  test('flush only touches the requested peer', () async {
    final attempted = <String>[];
    final outbox = OutboxService()
      ..send = (peer, payload) async {
        attempted.add(peer);
        return false;
      };

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'a');
    await outbox.enqueue(id: 'm2', peer: 'carol', payload: 'b');
    attempted.clear();

    await outbox.flush(onlyPeer: 'bob');

    expect(attempted, ['bob']);
  });

  test('unsent messages survive a restart', () async {
    final first = OutboxService()..send = (_, __) async => false;
    await first.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');

    // A new instance, as after the process is killed and relaunched.
    final restored = OutboxService()..send = (_, __) async => true;
    await restored.load();

    expect(restored.pendingCount, 1);
    expect(restored.stateOf('m1'), OutboxState.pending);

    await restored.flush();
    expect(restored.stateOf('m1'), OutboxState.sent);
  });

  test('a delivery receipt advances the state', () async {
    final outbox = OutboxService()..send = (_, __) async => true;
    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');
    expect(outbox.stateOf('m1'), OutboxState.sent);

    await outbox.markDelivered('m1');
    expect(outbox.stateOf('m1'), OutboxState.delivered);
  });

  test('the same message is never queued twice', () async {
    final outbox = OutboxService()..send = (_, __) async => false;

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');
    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed again');

    expect(outbox.entries.length, 1);
    expect(outbox.entries.single.payload, 'sealed');
  });

  test('gives up after maxAttempts, and can be retried by hand', () async {
    final outbox = OutboxService()..send = (_, __) async => false;
    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');

    for (var i = 1; i < OutboxService.maxAttempts; i++) {
      await outbox.flush();
    }
    expect(outbox.stateOf('m1'), OutboxState.failed);

    outbox.send = (_, __) async => true;
    await outbox.retry('m1');
    expect(outbox.stateOf('m1'), OutboxState.sent);
  });

  test('a concurrent flush does not send the same entry twice', () async {
    var deliveries = 0;
    final outbox = OutboxService()
      ..send = (_, __) async {
        deliveries++;
        // Yield, so the second flush overlaps the first.
        await Future<void>.delayed(Duration.zero);
        return true;
      };

    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'sealed');
    deliveries = 0;

    await Future.wait([outbox.flush(), outbox.flush(), outbox.flush()]);

    expect(deliveries, 0, reason: 'entry was already sent by enqueue');
  });

  test('deleting a conversation clears its queued messages', () async {
    final outbox = OutboxService()..send = (_, __) async => false;
    await outbox.enqueue(id: 'm1', peer: 'bob', payload: 'a');
    await outbox.enqueue(id: 'm2', peer: 'carol', payload: 'b');

    await outbox.removeForPeer('bob');

    expect(outbox.entries.map((e) => e.peer), ['carol']);
  });

  test('pruning keeps unsent messages and drops old finished ones', () async {
    // Only Carol is reachable, so Bob's message stays pending throughout.
    final outbox = OutboxService()
      ..send = (peer, _) async => peer == 'carol';

    await outbox.enqueue(id: 'pending', peer: 'bob', payload: 'a');
    await outbox.enqueue(id: 'sent', peer: 'carol', payload: 'b');

    expect(outbox.stateOf('pending'), OutboxState.pending);
    expect(outbox.stateOf('sent'), OutboxState.sent);

    // Nothing is old enough yet.
    await outbox.pruneCompleted();
    expect(outbox.entries.length, 2);

    await outbox.pruneCompleted(keepFor: Duration.zero);
    expect(outbox.entries.map((e) => e.id), ['pending']);
  });
}
