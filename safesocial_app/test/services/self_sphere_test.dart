import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// The built-in sphere with one member. Derived from the identity rather
/// than minted, so every device of the same identity has the same one with
/// the same key; it cannot be renamed, left or opened to anyone.
void main() {
  late String me, secret;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();
    final k = ed.generateKey();
    me = hex.encode(k.publicKey.bytes);
    secret = hex.encode(k.privateKey.bytes);
  });

  SphereService service() => SphereService()
    ..configure(
        sessions: SessionManager(),
        identityKey: me,
        identitySecret: secret,
        resolveExchangeKey: (_) => null);

  test('exists after ensureSelf, with one member, and is the same on every call', () async {
    final s = service();
    expect(s.selfSphere, isNull);
    final self = await s.ensureSelf();
    expect(self.name, 'Self');
    expect(self.members.map((m) => m.identityKey), [me]);
    expect(s.isSelf(self.id), isTrue);
    expect(s.keyring.hasKey(self.id, 1), isTrue);

    final again = await s.ensureSelf();
    expect(again.id, self.id);
    expect(s.spheres.where((x) => x.id == self.id).length, 1);
  });

  test('two devices of one identity derive the same sphere and the same key, unasked', () async {
    final a = service(), b = service();
    final sa = await a.ensureSelf();
    final sb = await b.ensureSelf();
    expect(sa.id, sb.id);
    expect(a.keyring.keyFor(sa.id, 1), b.keyring.keyFor(sb.id, 1));
    expect(sa.id, SphereService.selfSphereIdFor(me));
  });

  test('another identity gets another sphere', () {
    final other = hex.encode(ed.generateKey().publicKey.bytes);
    expect(SphereService.selfSphereIdFor(me), isNot(SphereService.selfSphereIdFor(other)));
  });

  test('cannot be renamed, left or opened to anyone', () async {
    final s = service();
    final self = await s.ensureSelf();
    final other = hex.encode(ed.generateKey().publicKey.bytes);
    await expectLater(s.rename(self.id, name: 'Me'), throwsStateError);
    await expectLater(s.leave(self.id), throwsStateError);
    await expectLater(s.addMember(self.id, other), throwsStateError);
    expect(s.spheres.any((x) => x.id == self.id), isTrue);
  });
}
