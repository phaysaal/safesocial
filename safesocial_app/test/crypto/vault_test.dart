import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/vault.dart';

/// The vault is what re-enables encrypted backup and identity export, both
/// disabled in Phase 0 because the Rust stub they used returned a fixed string
/// and silently discarded the key. So the thing to pin is that a vault really
/// does depend on the passphrase, and fails closed when anything is off.
void main() {
  const secret = '{"key":"abc","secret":"def"}';

  test('round trips with the right passphrase', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'correct horse');

    expect(await Vault.open(vault: vault, passphrase: 'correct horse'), secret);
  });

  test('the sealed vault does not contain the plaintext', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'pw');

    expect(vault, isNot(contains('abc')));
    expect(vault, isNot(contains('def')));
  });

  test('a wrong passphrase fails', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'right');

    await expectLater(
      Vault.open(vault: vault, passphrase: 'wrong'),
      throwsA(isA<VaultException>()),
    );
  });

  test('an empty passphrase is refused at seal time', () async {
    // The old flow accepted one and wrote an unencrypted file that still
    // looked like a backup.
    await expectLater(
      Vault.seal(plaintext: secret, passphrase: ''),
      throwsA(isA<VaultException>()),
    );
  });

  test('two vaults of the same content differ', () async {
    final a = await Vault.seal(plaintext: secret, passphrase: 'pw');
    final b = await Vault.seal(plaintext: secret, passphrase: 'pw');

    // Fresh salt and nonce each time.
    expect(a, isNot(b));
    expect(await Vault.open(vault: a, passphrase: 'pw'), secret);
    expect(await Vault.open(vault: b, passphrase: 'pw'), secret);
  });

  test('a tampered ciphertext is refused', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'pw');
    final json = jsonDecode(vault) as Map<String, dynamic>;
    final ct = base64Decode(json['ct'] as String);
    ct[0] ^= 0x01;
    json['ct'] = base64Encode(ct);

    await expectLater(
      Vault.open(vault: jsonEncode(json), passphrase: 'pw'),
      throwsA(isA<VaultException>()),
    );
  });

  test('weakening the stored work factor breaks the vault', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'pw');
    final json = jsonDecode(vault) as Map<String, dynamic>;
    json['m'] = 8;
    json['t'] = 1;

    // The header is bound as associated data, so an attacker cannot edit the
    // parameters down to make brute-forcing cheaper.
    await expectLater(
      Vault.open(vault: jsonEncode(json), passphrase: 'pw'),
      throwsA(isA<VaultException>()),
    );
  });

  test('an implausible work factor is refused rather than attempted', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'pw');
    final json = jsonDecode(vault) as Map<String, dynamic>;
    json['m'] = 1024 * 1024 * 8;

    // A hostile file must not be able to exhaust memory on open.
    await expectLater(
      Vault.open(vault: jsonEncode(json), passphrase: 'pw'),
      throwsA(isA<VaultException>()),
    );
  });

  test('non-vault input is rejected clearly', () async {
    await expectLater(
      Vault.open(vault: 'not json', passphrase: 'pw'),
      throwsA(isA<VaultException>()),
    );
    await expectLater(
      Vault.open(vault: '{"status":"success","vault_blob":"placeholder_vault_blob"}',
          passphrase: 'pw'),
      throwsA(isA<VaultException>()),
    );
  });

  test('vaults are recognisable without trying a passphrase', () async {
    final vault = await Vault.seal(plaintext: secret, passphrase: 'pw');

    expect(Vault.looksLikeVault(vault), isTrue);
    expect(Vault.looksLikeVault(base64Encode(utf8.encode(secret))), isFalse);
    expect(Vault.looksLikeVault('placeholder_vault_blob'), isFalse);
  });
}
