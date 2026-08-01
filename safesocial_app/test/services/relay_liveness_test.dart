import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/relay_service.dart';

/// A WebSocket can stop delivering without ever closing — a NAT drops an idle
/// mapping, the network hands over, the relay lets the socket go. `onDone`
/// never fires, so the reconnect logic never runs, and the app sits there
/// believing it is connected while messages pile up in a mailbox it is no
/// longer reading.
///
/// Seen on two devices: a peer's reply reached the relay, the recipient's app
/// was running and idle, and nothing arrived until it was restarted.
///
/// The check is deliberately evidence-based rather than a guess about socket
/// health: fetch the mailbox over HTTP, which does not involve the socket at
/// all, and if anything was waiting then the socket demonstrably failed to
/// deliver it and is replaced. These tests cover the parts that do not need a
/// relay; the behaviour itself was verified on devices.
void main() {
  test('checking every client is safe with none connected', () async {
    // Runs on every app resume, including before anything is wired.
    await RelayService.verifyAll();
  });

  test('a client with no connections has nothing to check', () async {
    final service = RelayService();

    await service.verifyIdleConnections();

    expect(service.stateFor('nobody'),
        RelayConnectionState.disconnected);
  });

  test('the idle threshold is short enough to matter', () {
    // Long enough not to poll a healthy connection, short enough that a dead
    // one is noticed within a couple of minutes rather than at next restart.
    expect(RelayService.idleBefore, lessThanOrEqualTo(const Duration(minutes: 5)));
    expect(RelayService.idleBefore,
        greaterThanOrEqualTo(const Duration(seconds: 30)));
  });

  test('disposing stops a client being checked again', () async {
    final service = RelayService();
    service.dispose();

    // Would throw if a disposed client were still in the set and notified.
    await RelayService.verifyAll();
  });
}
