import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/services/backup_service.dart';

/// These tests pin the Phase 0 guarantee that restoring a backup can never
/// silently replace a working identity with an empty or malformed one.
///
/// Every case below must fail *before* any storage write happens, so a
/// rejected restore leaves the device untouched. That is why none of them need
/// SharedPreferences or secure-storage mocks — reaching storage at all would
/// itself be the bug.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('spheres_backup_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> writeBackup(String contents) async {
    final f = File('${tmp.path}/test.spheres');
    await f.writeAsString(contents);
    return f.path;
  }

  String encode(Map<String, dynamic> payload) =>
      base64Encode(utf8.encode(jsonEncode(payload)));

  Map<String, dynamic> validPayload() => {
        'identity': {'publicKey': 'aa', 'displayName': 'Test', 'bio': ''},
        'keypair': {'key': 'aa', 'secret': 'bb'},
        'contacts': [],
        'posts': [],
        'version': BackupService.formatVersion,
      };

  test('rejects a legacy placeholder vault instead of wiping the identity', () async {
    // 0.4.7 and earlier wrote this literal string when a passphrase was given,
    // because the Rust vault primitives were stubs. Restoring it produced an
    // empty identity that could not be undone.
    final path = await writeBackup(
      jsonEncode({'status': 'success', 'vault_blob': 'placeholder_vault_blob'}),
    );

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('placeholder'),
      )),
    );
  });

  test('rejects a file that is not a backup', () async {
    final path = await writeBackup('this is not base64 json at all !!!');

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('corrupt'),
      )),
    );
  });

  test('rejects a backup with no keypair', () async {
    final payload = validPayload()..remove('keypair');
    final path = await writeBackup(encode(payload));

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('no identity keypair'),
      )),
    );
  });

  test('rejects a backup whose keypair fields are empty', () async {
    final payload = validPayload()..['keypair'] = {'key': '', 'secret': ''};
    final path = await writeBackup(encode(payload));

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>()),
    );
  });

  test('rejects a backup written by a newer format version', () async {
    final payload = validPayload()
      ..['version'] = BackupService.formatVersion + 1;
    final path = await writeBackup(encode(payload));

    await expectLater(
      BackupService().restoreBackup(path),
      throwsA(isA<Exception>().having(
        (e) => e.toString(),
        'message',
        contains('Unsupported backup format'),
      )),
    );
  });

  test('rejects a missing file', () async {
    await expectLater(
      BackupService().restoreBackup('${tmp.path}/does_not_exist.spheres'),
      throwsA(isA<Exception>()),
    );
  });
}
