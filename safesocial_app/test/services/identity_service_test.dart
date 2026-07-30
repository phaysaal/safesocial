import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/vault.dart';
import 'package:spheres_app/services/identity_service.dart';

/// Export and import are real now (Argon2id + XChaCha20-Poly1305 via Vault);
/// they used to return a fixed placeholder string that discarded the key.
///
/// Only paths that return before any storage write are covered here, so no
/// platform channel mocks are needed. The vault itself is covered in
/// test/crypto/vault_test.dart.
void main() {
  test('export with no identity fails instead of emitting an empty vault', () async {
    await expectLater(
      IdentityService().exportIdentity('correct horse battery staple'),
      throwsA(isA<Exception>()),
    );
  });

  test('a vault with the wrong passphrase does not import', () async {
    final vault = await Vault.seal(
      plaintext: jsonEncode({'key': 'aa', 'secret': 'bb'}),
      passphrase: 'the right one',
    );

    await expectLater(
      IdentityService().importIdentity(vault, passphrase: 'the wrong one'),
      throwsA(isA<VaultException>()),
    );
  });

  test('a legacy placeholder blob does not import', () async {
    // What the old Rust stub produced. It must not be mistaken for an identity.
    expect(
      await IdentityService()
          .importIdentity('{"status":"success","vault_blob":"placeholder_vault_blob"}'),
      isFalse,
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
