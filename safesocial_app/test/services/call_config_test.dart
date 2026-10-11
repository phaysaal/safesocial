import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/services/call_config.dart';

/// Calls used to default to a free public TURN service run by a company
/// nobody here has a relationship with, with its credentials in the binary.
/// Now the relay issues short-lived credentials for the operator's own
/// server; these pin how the client treats what the relay says.
void main() {
  late CallConfig config;
  var clock = DateTime(2026, 10, 11, 12);

  Map<String, dynamic> issued({int ttl = 7200}) => {
        'configured': true,
        'urls': ['turn:turn.example.eu:3478', 'turns:turn.example.eu:5349'],
        'username': '1760000000:abc',
        'credential': 'mac==',
        'ttl': ttl,
      };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    CallConfig.now = () => clock;
    CallConfig.forgetIssued();
    config = CallConfig();
    await config.resetToDefault();
  });

  tearDown(() => CallConfig.now = DateTime.now);

  test('relay credentials become TURN entries plus a STUN on the same host',
      () async {
    final servers = await CallConfig.resolve(() async => issued());

    expect(servers.first, {'urls': 'stun:turn.example.eu:3478'});
    final turn = servers.where((s) => s['urls']!.startsWith('turn')).toList();
    expect(turn, hasLength(2));
    for (final s in turn) {
      expect(s['username'], '1760000000:abc');
      expect(s['credential'], 'mac==');
    }
    expect(CallConfig.relayOffersTurn, isTrue);
    expect(config.summary, contains('issued by your relay'));
    expect(servers.any((s) => s['urls']!.contains('openrelay')), isFalse);
  });

  test('a relay without TURN falls back to public STUN, and says so', () async {
    final servers = await CallConfig.resolve(
        () async => {'configured': false, 'error': 'TURN is not configured'});

    expect(servers, CallConfig.fallbackStun);
    expect(CallConfig.relayOffersTurn, isFalse);
    expect(config.summary, contains('offers no TURN'));
  });

  test('an unreachable relay also falls back rather than failing the call',
      () async {
    final servers = await CallConfig.resolve(() async => null);
    expect(servers, CallConfig.fallbackStun);
  });

  test('issued credentials are reused until most of their lifetime has passed',
      () async {
    var fetches = 0;
    Future<Map<String, dynamic>?> fetch() async {
      fetches++;
      return issued(ttl: 1000);
    }

    await CallConfig.resolve(fetch);
    clock = clock.add(const Duration(seconds: 700));
    await CallConfig.resolve(fetch);
    expect(fetches, 1, reason: '80% of 1000s not yet reached');

    clock = clock.add(const Duration(seconds: 200));
    await CallConfig.resolve(fetch);
    expect(fetches, 2);
  });

  test('with TURN switched off only the STUN entries are used', () async {
    await config.setTurnEnabled(false);

    final servers = await CallConfig.resolve(() async => issued());

    expect(servers, [
      {'urls': 'stun:turn.example.eu:3478'}
    ]);
    expect(config.summary, contains('no TURN relay'));
  });

  test('relay-only is off by default and forces the ICE transport policy',
      () async {
    final servers = await CallConfig.resolve(() async => issued());
    expect(CallConfig.peerConnectionConfig(servers).containsKey('iceTransportPolicy'),
        isFalse);

    await config.setRelayOnly(true);
    expect(CallConfig.peerConnectionConfig(servers)['iceTransportPolicy'], 'relay');
    expect(CallConfig.peerConnectionConfig(servers)['iceServers'], servers);
    expect(config.summary, contains('relayed through TURN'));

    // Without TURN there is nothing to relay through: the policy must not
    // turn every call into a guaranteed failure.
    await config.setTurnEnabled(false);
    expect(CallConfig.peerConnectionConfig(servers).containsKey('iceTransportPolicy'),
        isFalse);

    await config.resetToDefault();
    expect(config.relayOnlyEnabled, isFalse);
  });

  test('custom servers win and the relay is not asked', () async {
    var asked = false;
    expect(await config.setCustom('turn:my.turn:3478,u,p\nstun:my.turn:3478'),
        isNull);

    final servers = await CallConfig.resolve(() async {
      asked = true;
      return issued();
    });

    expect(asked, isFalse);
    expect(servers, [
      {'urls': 'turn:my.turn:3478', 'username': 'u', 'credential': 'p'},
      {'urls': 'stun:my.turn:3478'},
    ]);
    expect(config.isCustom, isTrue);
  });

  test('a custom line that is not stun/turn/turns is refused', () async {
    expect(await config.setCustom('http://not.a.server'), isNotNull);
    expect(await config.setCustom('turn:x:1,only-one-extra'), isNotNull);
    expect(await config.setCustom('turns:x:5349,u,p'), isNull);
  });

  test('changing relay forgets issued credentials', () async {
    await CallConfig.resolve(() async => issued());
    expect(CallConfig.relayOffersTurn, isTrue);

    CallConfig.forgetIssued();

    expect(CallConfig.relayOffersTurn, isNull);
    var fetches = 0;
    await CallConfig.resolve(() async {
      fetches++;
      return issued();
    });
    expect(fetches, 1);
  });
}
