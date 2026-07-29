import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/identity_service.dart';

/// Phase 0 guarantee: the identity export/import paths that used to report
/// success while discarding the key must now fail loudly.
///
/// Only the rejection paths are covered here — they all return before any
/// storage write, so no platform channel mocks are needed. Success paths need
/// SharedPreferences and secure storage and are covered once real vault
/// encryption lands.
void main() {
  test('encrypted export refuses rather than producing a keyless blob', () async {
    // Previously returned the literal string "placeholder_vault_blob", which
    // callers wrote to disk and treated as a backup of the identity.
    await expectLater(
      IdentityService().exportIdentity('correct horse battery staple'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('passphrase-protected import refuses rather than silently failing', () async {
    await expectLater(
      IdentityService().importIdentity('anything', passphrase: 'hunter2'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('import rejects a blob that is not JSON', () async {
    expect(await IdentityService().importIdentity('not json'), isFalse);
  });

  test('import rejects a blob with no keypair fields', () async {
    final blob = jsonEncode({'profile': {'displayName': 'Someone'}});
    expect(await IdentityService().importIdentity(blob), isFalse);
  });

  test('import rejects a blob with empty keypair fields', () async {
    final blob = jsonEncode({'key': '', 'secret': ''});
    expect(await IdentityService().importIdentity(blob), isFalse);
  });

  test('import rejects a blob whose keypair fields are the wrong type', () async {
    final blob = jsonEncode({'key': 123, 'secret': null});
    expect(await IdentityService().importIdentity(blob), isFalse);
  });
}
