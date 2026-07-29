import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// A direct message is a sphere of two. It is derived rather than created, so
/// there is no invitation to accept and the two devices cannot disagree about
/// what it is.
void main() {
  late String alice;
  late String bob;
  late SphereService alices;
  late SphereService bobs;

  SphereService serviceFor(ed.KeyPair k) {
    final s = SphereService();
    s.configure(
      sessions: SessionManager(),
      identityKey: hex.encode(k.publicKey.bytes),
      identitySecret: hex.encode(k.privateKey.bytes),
      resolveExchangeKey: (_) => null,
    );
    return s;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final a = ed.generateKey();
    final b = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    bob = hex.encode(b.publicKey.bytes);
    alices = serviceFor(a);
    bobs = serviceFor(b);
  });

  test('both sides derive the same DM sphere without talking', () {
    final fromAlice = alices.directSphereWith(bob);
    final fromBob = bobs.directSphereWith(alice);

    expect(fromAlice.id, fromBob.id);
    expect(fromAlice.kind, SphereKind.direct);
    expect(fromAlice.members.length, 2);
    expect(fromAlice.contains(alice), isTrue);
    expect(fromAlice.contains(bob), isTrue);
  });

  test('a different peer gives a different sphere', () {
    final carol = hex.encode(ed.generateKey().publicKey.bytes);

    expect(alices.directSphereWith(bob).id,
        isNot(alices.directSphereWith(carol).id));
  });

  test('derivation is stable across calls', () {
    expect(alices.directSphereWith(bob).id, alices.directSphereWith(bob).id);
  });

  test('both participants are admins, so neither can remove the other', () {
    final sphere = alices.directSphereWith(bob);

    expect(sphere.isAdmin(alice), isTrue);
    expect(sphere.isAdmin(bob), isTrue);
  });

  test('a DM sphere is recognised among a contact list', () {
    final carol = hex.encode(ed.generateKey().publicKey.bytes);
    final dm = alices.directSphereWith(bob);

    expect(alices.isDirectSphere(dm.id, [carol, bob]), isTrue);
    expect(alices.isDirectSphere(dm.id, [carol]), isFalse);
  });

  test('the id does not leak the participants', () {
    final sphere = alices.directSphereWith(bob);

    // It is a hash, not a concatenation — the relay never sees it anyway, but
    // it should not be a directory of who talks to whom if it leaks.
    expect(sphere.id.contains(alice), isFalse);
    expect(sphere.id.contains(bob), isFalse);
    expect(sphere.id.length, 64);
  });
}
