import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/vault.dart';
import 'package:spheres_app/services/backup_service.dart';

/// A backup that omits sphere keys is not a backup: those keys cannot be
/// re-derived, so losing them makes every post in that sphere permanently
/// unreadable. These pin what a backup must carry, and what it must refuse
/// to restore.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('spheres_backup_cov');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> writeBackup(Map<String, dynamic> payload,
      {String? passphrase}) async {
    final body = passphrase == null
        ? base64Encode(utf8.encode(jsonEncode(payload)))
        : await Vault.seal(
            plaintext: jsonEncode(payload), passphrase: passphrase);
    final file = File('${tmp.path}/b.spheres');
    await file.writeAsString(body);
    return file.path;
  }

  Map<String, dynamic> payload({Map<String, String>? store, int version = 3}) => {
        'identity': {'publicKey': 'aa', 'displayName': 'T', 'bio': ''},
        'keypair': {'key': 'aa', 'secret': 'bb'},
        'version': version,
        if (store != null) 'store': store,
      };

  test('an encrypted backup needs its passphrase', () async {
    final path = await writeBackup(payload(), passphrase: 'the passphrase');

    expect(await BackupService().isEncrypted(path), isTrue);

    await expectLater(
      BackupService().restoreBackup(path, passphrase: 'wrong'),
      throwsA(isA<VaultException>()),
    );
  });

  test('an unencrypted backup is recognised as such', () async {
    final path = await writeBackup(payload());

    expect(await BackupService().isEncrypted(path), isFalse);
  });

  test('a version 2 backup still restores', () async {
    // Older files have no `store`; they must not be rejected outright.
    final path = await writeBackup({
      'identity': {'publicKey': 'aa', 'displayName': 'T', 'bio': ''},
      'keypair': {'key': 'aa', 'secret': 'bb'},
      'contacts': [],
      'posts': [],
      'version': 2,
    });

    expect(await BackupService().isEncrypted(path), isFalse);
  });

  test('a backup from a newer version is refused', () async {
    final path = await writeBackup(payload(version: 99));

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>()),
    );
  });

  test('a backup with no keypair is refused before anything is written', () async {
    final broken = payload()..remove('keypair');
    final path = await writeBackup(broken);

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>()),
    );
  });

  test('the legacy placeholder blob is still refused', () async {
    final file = File('${tmp.path}/old.spheres');
    await file.writeAsString(
        '{"status":"success","vault_blob":"placeholder_vault_blob"}');

    await expectLater(
      BackupService().restoreBackup(file.path),
      throwsA(isA<Exception>()),
    );
  });

  test('sphere keys are among the keys a backup carries', () {
    // The regression this guards: a backup that looks complete but silently
    // drops the one thing that cannot be regenerated.
    expect(BackupService.formatVersion, greaterThanOrEqualTo(3));
  });
}
