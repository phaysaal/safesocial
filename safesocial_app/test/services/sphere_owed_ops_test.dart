import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Found on hardware, 27 October 2026: approving a join request added the
/// requester and sent them the add straight away, before their channel was
/// up. The relay took nothing, the result was ignored, and the newcomer never
/// heard of the sphere. Now what a member's channel does not take is kept and
/// sent when that channel comes up, across a restart too.
void main() {
  late String alice, aliceSecret, maya;
  late SessionManager sessions;
  late String mayaExchange;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    maya = hex.encode(ed.generateKey().publicKey.bytes);
    sessions = SessionManager();
    await sessions.configure(
        keyExchangeKeyPair: await SpheresCrypto.newKeyExchangeKeyPair(), identityKey: alice, identitySecret: aliceSecret);
    final mayaPair = await SpheresCrypto.newKeyExchangeKeyPair();
    mayaExchange = hex.encode((await mayaPair.extractPublicKey()).bytes);
  });

  SphereService aliceDevice() => SphereService()
    ..configure(
      sessions: sessions,
      identityKey: alice,
      identitySecret: aliceSecret,
      resolveExchangeKey: (k) => k == maya ? mayaExchange : null,
    );

  test('an add the new member\'s channel did not take is sent when it comes up', () async {
    final s = aliceDevice();
    var channelUp = false;
    final delivered = <String>[];
    s.sendToPeer = (peer, sealed, {deviceKey}) async {
      if (!channelUp) return false;
      delivered.add(peer);
      return true;
    };
    final family = await s.create(name: 'Family', kind: SphereKind.group);
    await s.addMember(family.id, maya);

    expect(delivered, isEmpty, reason: 'the channel was not up');
    expect(s.owes(maya), isTrue, reason: 'before the fix this was dropped');

    channelUp = true;
    await s.resendOwed(maya);
    expect(delivered, [maya]);
    expect(s.owes(maya), isFalse);

    // Nothing is sent twice.
    await s.resendOwed(maya);
    expect(delivered, [maya]);
  });

  test('what is owed survives a restart', () async {
    final s = aliceDevice();
    s.sendToPeer = (peer, sealed, {deviceKey}) async => false;
    final family = await s.create(name: 'Family', kind: SphereKind.group);
    await s.addMember(family.id, maya);
    expect(s.owes(maya), isTrue);

    final again = aliceDevice();
    await again.load();
    expect(again.owes(maya), isTrue);
    final delivered = <String>[];
    again.sendToPeer = (peer, sealed, {deviceKey}) async {
      delivered.add(peer);
      return true;
    };
    await again.resendOwed(maya);
    expect(delivered, [maya]);
    expect(again.owes(maya), isFalse);
  });

  test('a later op that is taken clears what was owed; a member since removed is owed nothing', () async {
    final s = aliceDevice();
    var up = false;
    s.sendToPeer = (peer, sealed, {deviceKey}) async => up;
    final family = await s.create(name: 'Family', kind: SphereKind.group);
    await s.addMember(family.id, maya);
    expect(s.owes(maya), isTrue);
    up = true;
    await s.rename(family.id, name: 'Our family');
    expect(s.owes(maya), isFalse, reason: 'the rename carried the whole state and was taken');

    up = false;
    await s.rename(family.id, name: 'Family again');
    expect(s.owes(maya), isTrue);
    await s.removeMember(family.id, maya);
    final delivered = <String>[];
    s.sendToPeer = (peer, sealed, {deviceKey}) async {
      delivered.add(peer);
      return true;
    };
    await s.resendOwed(maya);
    expect(delivered, isEmpty);
    expect(s.owes(maya), isFalse);
  });
}
