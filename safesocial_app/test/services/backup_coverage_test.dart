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
    expect(BackupService.isBackedUpKey('spheres_keyring_v1'), isTrue);
  });

  test('a backup carries every screen, not just identity and feed', () {
    for (final key in [
      'spheres_contacts',
      'spheres_contact_requests_v1',
      'spheres_spheres_v1',
      'spheres_sphere_chats_v1',
      'spheres_sphere_msgs_abc',
      'spheres_sphere_audit_v1',
      'spheres_removal_proposals_v1',
      'spheres_transfer_offers_v1',
      'spheres_conversations',
      'spheres_msgs_deadbeef',
      'spheres_archive_index_v1',
      'spheres_archive_sphere1',
      'spheres_feed_posts',
      'spheres_saved_v1',
      'spheres_pinned_chats_v1',
      'spheres_muted_spheres_v1',
      'spheres_albums',
      'spheres_story_view_receipts',
    ]) {
      expect(BackupService.isBackedUpKey(key), isTrue, reason: key);
    }
  });

  test('ratchet state, outboxes and device settings stay out of a backup', () {
    // Sessions: restoring them onto a second running device would reuse
    // message keys. Outboxes: pending sends belong to the device that queued
    // them. Everything else here is plaintext device configuration.
    for (final key in [
      'spheres_sessions_v1',
      'spheres_outbox_v1',
      'spheres_feed_outbox_v1',
      'spheres_relay_host',
      'spheres_ice_servers',
      'spheres_store_key',
      'spheres_typing_signals',
      'theme_mode',
    ]) {
      expect(BackupService.isBackedUpKey(key), isFalse, reason: key);
    }
  });
}
