import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/relay_service.dart';
import 'package:spheres_app/services/sync_service.dart';

class _FakeSocket implements RelaySocket {
  final sent = <Map<String, dynamic>>[];
  final _incoming = StreamController<dynamic>.broadcast();
  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => _incoming.stream;
  @override
  void send(String frame) => sent.add(jsonDecode(frame) as Map<String, dynamic>);
  @override
  Future<void> close() async => _incoming.close();
  void receive(Map<String, Object?> frame) => _incoming.add(jsonEncode(frame));
  Iterable<Map<String, dynamic>> ofType(String t) => sent.where((f) => f['t'] == t);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late _FakeSocket socket;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    RelayHub.instance.debugReset();
    socket = _FakeSocket();
    RelayHub.instance.connector = (_) => socket;
    RelayHub.instance.syncOverride = (_, __) async => 0;
    SyncService.pairingConnectTimeout = const Duration(milliseconds: 150);
  });

  tearDown(() => RelayHub.instance.debugReset());

  const code = 'Z9MaR7q2FVwoskuDoITYSmLDH2Qa/nCeMchz7FwU7MI=';

  test('the join request waits for the pairing mailbox to be confirmed', () async {
    final sync = SyncService();
    final result = sync.startSecondaryLinking(code, deviceName: 'Moto');
    await settle();
    final sub = socket.ofType('sub').single;
    expect(socket.ofType('pub'), isEmpty,
        reason: 'nothing may be published before the relay confirms');

    socket.receive({'t': 'ok', 'a': sub['a']});
    await settle();
    final pub = socket.ofType('pub').single;
    expect(pub['a'], sub['a']);
    expect(pub['d'], contains('link_request'));
    expect(pub['d'], contains('Moto'));

    socket.receive({'t': 'sent', 'a': pub['a'], 'id': pub['id']});
    expect(await result, isNull);
    expect(sync.isLinking, isTrue);
  });

  test('a relay that never confirms is reported, not waited on forever', () async {
    final sync = SyncService();
    final problem = await sync.startSecondaryLinking(code);
    expect(problem, contains('Could not reach the relay'));
    expect(sync.lastResult, problem);
    expect(sync.isLinking, isFalse);
    expect(socket.ofType('pub'), isEmpty);
  });

  test('a request the relay refuses is reported', () async {
    final sync = SyncService();
    final result = sync.startSecondaryLinking(code);
    await settle();
    final sub = socket.ofType('sub').single;
    socket.receive({'t': 'ok', 'a': sub['a']});
    await settle();
    final pub = socket.ofType('pub').single;
    socket.receive({'t': 'err', 'a': pub['a'], 'e': 'full'});
    final problem = await result;
    expect(problem, contains('did not take'));
    expect(sync.isLinking, isFalse);
  });
}
