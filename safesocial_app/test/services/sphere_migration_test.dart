import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/services/sphere_migration.dart';
import 'package:spheres_app/services/sphere_service.dart';

void main() {
  late SphereService service;
  late String me;

  SphereService build() {
    final s = SphereService();
    final key = ed.generateKey();
    me = hex.encode(key.publicKey.bytes);
    s.configure(
      sessions: SessionManager(),
      identityKey: me,
      identitySecret: hex.encode(key.privateKey.bytes),
      resolveExchangeKey: (_) => null,
    );
    return s;
  }

  test('legacy groups become spheres with their members', () async {
    SharedPreferences.setMockInitialValues({
      'spheres_groups': jsonEncode([
        {
          'dhtKey': 'uuid-1',
          'name': 'Climbing',
          'members': [
            {'publicKey': 'aaa'},
            {'publicKey': 'bbb'},
          ],
        },
      ]),
    });
    service = build();

    final created = await SphereMigration.run(service);

    expect(created, 1);
    final sphere = service.spheres.single;
    expect(sphere.name, 'Climbing');
    expect(sphere.contains('aaa'), isTrue);
    expect(sphere.contains('bbb'), isTrue);
    // The migrating device is the admin — it is the only party that ever knew
    // about this group.
    expect(sphere.isAdmin(me), isTrue);
  });

  test('populated rings become spheres', () async {
    SharedPreferences.setMockInitialValues({
      'spheres_rings': jsonEncode([
        {
          'id': 'inner_circle',
          'name': 'Inner Circle',
          'memberPublicKeys': ['aaa'],
        },
      ]),
    });
    service = build();

    await SphereMigration.run(service);

    expect(service.spheres.single.name, 'Inner Circle');
    expect(service.spheres.single.contains('aaa'), isTrue);
  });

  test('the empty rings seeded on first run are skipped', () async {
    // Every install got "Inner Circle" and "Family" whether or not they were
    // used; migrating those would leave everyone with empty spheres.
    SharedPreferences.setMockInitialValues({
      'spheres_rings': jsonEncode([
        {'id': 'inner_circle', 'name': 'Inner Circle', 'memberPublicKeys': []},
        {'id': 'family', 'name': 'Family', 'memberPublicKeys': []},
      ]),
    });
    service = build();

    expect(await SphereMigration.run(service), 0);
    expect(service.spheres, isEmpty);
  });

  test('migration runs only once', () async {
    SharedPreferences.setMockInitialValues({
      'spheres_groups': jsonEncode([
        {
          'dhtKey': 'uuid-1',
          'name': 'Climbing',
          'members': [
            {'publicKey': 'aaa'}
          ],
        },
      ]),
    });
    service = build();

    expect(await SphereMigration.run(service), 1);
    expect(await SphereMigration.run(service), 0);
    expect(service.spheres.length, 1);
  });

  test('malformed legacy data does not block startup', () async {
    SharedPreferences.setMockInitialValues({
      'spheres_groups': 'not json at all',
    });
    service = build();

    expect(await SphereMigration.run(service), 0);
    expect(service.spheres, isEmpty);
  });

  test('nothing to migrate is fine', () async {
    SharedPreferences.setMockInitialValues({});
    service = build();

    expect(await SphereMigration.run(service), 0);
  });
}
