import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'secure_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/vault.dart';
import 'debug_log_service.dart';

/// Handles creation and restoration of local backups.
///
/// Backups may be passphrase-encrypted with [Vault] (Argon2id +
/// XChaCha20-Poly1305). Encryption previously routed through a Rust stub that
/// returned the literal string `placeholder_vault_blob`, so an "encrypted"
/// backup contained no key material and restoring one silently produced an
/// empty identity — which is why the feature was disabled. An unencrypted
/// backup is still offered, and the caller must say so plainly.
class BackupService extends ChangeNotifier {
  final _secureStorage = const FlutterSecureStorage();

  /// Current backup payload format version.
  ///
  /// 3 added spheres, sphere keys, conversations and messages. 4 added sphere
  /// chats, the archive, governance state (audit log, votes, transfers), saved
  /// and muted and pinned items, contact requests and story receipts — so a
  /// restore reproduces every screen, not just the identity and the feed.
  /// Older files still restore; they simply carry less.
  static const int formatVersion = 4;

  /// Preference keys copied verbatim into a backup.
  ///
  /// Sphere keys are the critical entry: unlike sessions, they cannot be
  /// re-derived. Losing them makes every post in that sphere permanently
  /// unreadable, so a backup without them was not really a backup.
  static const List<String> _backedUpKeys = [
    'spheres_identity_profile',
    'spheres_devices_v1',
    'spheres_contacts',
    'spheres_contact_requests_v1',
    'spheres_contact_declined_v1',
    'spheres_feed_posts',
    'spheres_hidden_posts',
    'spheres_saved_v1',
    'spheres_story_view_receipts',
    'spheres_spheres_v1',
    'spheres_keyring_v1',
    'spheres_invites_v1',
    'spheres_sphere_audit_v1',
    'spheres_removal_proposals_v1',
    'spheres_transfer_offers_v1',
    'spheres_muted_spheres_v1',
    'spheres_muted_members_v1',
    'spheres_chat_settings_v1',
    'spheres_hidden_words_v1',
    'spheres_member_notes_v1',
    'spheres_drafts_v1',
    'spheres_reports_v1',
    'spheres_invite_tokens_v1',
    'spheres_call_log_v1',
    'spheres_chat_pins_v1',
    'spheres_starred_v1',
    'spheres_sphere_chat_settings_v1',
    'spheres_sphere_chat_pins_v1',
    'spheres_sphere_chat_unread_v1',
    'spheres_pinned_posts_v1',
    'spheres_archived_spheres_v1',
    'spheres_sphere_chats_v1',
    'spheres_albums',
    'spheres_conversations',
    'spheres_pinned_chats_v1',
    'spheres_blur_media_v1',
    'spheres_archive_index_v1',
  ];

  /// Per-conversation, per-sphere and per-archive entries, matched by prefix.
  static const List<String> _backedUpPrefixes = [
    'spheres_msgs_',
    'spheres_sphere_msgs_',
    'spheres_archive_',
  ];

  /// Whether a store key belongs in a backup, and may be written by a restore.
  static bool isBackedUpKey(String key) {
    if (key == _excludedSessionKey) return false;
    if (_backedUpKeys.contains(key)) return true;
    return _backedUpPrefixes.any(key.startsWith);
  }

  /// Everything a backup carries, for the UI to say so.
  static const String coverageSummary =
      'Identity and encryption keys, contacts and requests, spheres and their '
      'keys, governance history, chats and sphere chats, posts, comments, '
      'stories, albums, saved items and settings for pins and mutes. '
      'Pending outgoing messages and device-specific session state are not '
      'included; sessions re-establish themselves.';

  /// Ratchet state is deliberately NOT backed up. Restoring it onto a device
  /// that is also still running would let two devices advance the same chain,
  /// reusing message keys. Sessions re-derive from the identity key anyway;
  /// only ordering is lost, which the receiver tolerates.
  static const String _excludedSessionKey = 'spheres_sessions_v1';

  /// Create a full backup bundle.
  ///
  /// With a [passphrase] the file is encrypted. Without one it contains the
  /// Ed25519 secret key in cleartext (base64 of JSON — base64 is an encoding,
  /// not encryption), and should be treated as the identity itself.
  Future<String> createBackup({String? passphrase}) async {
    final finalData = await buildBackupData(passphrase: passphrase);
    final encrypted = passphrase != null && passphrase.isNotEmpty;

    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}/backups');
    if (!backupDir.existsSync()) await backupDir.create();

    final fileName = 'spheres_backup_${DateTime.now().millisecondsSinceEpoch}.spheres';
    final file = File('${backupDir.path}/$fileName');
    await file.writeAsString(finalData);

    DebugLogService().success('Backup',
        '${encrypted ? 'Encrypted' : 'Unencrypted'} backup created: $fileName');
    return file.path;
  }

  /// The backup as a string, encrypted when a passphrase is given. Also what
  /// travels to a device being linked, keyed by the pairing code.
  Future<String> buildBackupData({String? passphrase}) async {
    final prefs = SecureStore.instance;

    final pubKey = await prefs.getString('spheres_identity_pubkey');
    final secretKey = await _secureStorage.read(key: 'spheres_identity_secret');
    final exchangeSecret =
        await _secureStorage.read(key: 'spheres_identity_x25519_secret');

    if (pubKey == null || secretKey == null) {
      throw Exception('No identity on this device — nothing to back up');
    }

    // Everything under the backed-up keys, plus every conversation's messages.
    final store = <String, String>{};
    for (final key in await prefs.getKeys()) {
      if (!isBackedUpKey(key)) continue;
      final value = await prefs.getString(key);
      if (value != null) store[key] = value;
    }

    final profile = await prefs.getString('spheres_identity_profile');
    final contacts = await prefs.getString('spheres_contacts');
    final posts = await prefs.getString('spheres_feed_posts');

    final payload = {
      // Kept flat for compatibility with version 2 readers.
      'identity': profile != null ? jsonDecode(profile) : null,
      'keypair': {
        'key': pubKey,
        'secret': secretKey,
        if (exchangeSecret != null) 'exchangeSecret': exchangeSecret,
      },
      'contacts': contacts != null ? jsonDecode(contacts) : [],
      'posts': posts != null ? jsonDecode(posts) : [],
      'store': store,
      'version': formatVersion,
      'encrypted': false,
      'exported_at': DateTime.now().toIso8601String(),
    };

    final payloadJson = jsonEncode(payload);
    final encrypted = passphrase != null && passphrase.isNotEmpty;
    if (encrypted) payload['encrypted'] = true;

    return encrypted
        ? await Vault.seal(
            plaintext: jsonEncode(payload), passphrase: passphrase)
        : base64Encode(utf8.encode(payloadJson));
  }

  /// List all available backups.
  Future<List<File>> listBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}/backups');
    if (!backupDir.existsSync()) return [];

    return backupDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.spheres'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  /// Restore data from a backup file.
  ///
  /// This OVERWRITES the identity currently on this device, which is not
  /// recoverable afterwards. The payload is fully validated before anything is
  /// written, so a malformed or legacy placeholder file fails without touching
  /// existing state.

  /// Whether a backup file needs a passphrase, so the UI can ask only when it
  /// has to.
  Future<bool> isEncrypted(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    return Vault.looksLikeVault(await file.readAsString());
  }

  Future<void> restoreBackup(String filePath, {String? passphrase}) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('Backup file not found');
    await restoreBackupData(await file.readAsString(), passphrase: passphrase);
  }

  /// Restore from backup contents.
  ///
  /// With [asNewDevice] the X25519 key is *not* restored: this device is being
  /// added alongside the one the backup came from, and two devices sharing one
  /// session key is what corrupts conversations. It generates its own on load
  /// and adds itself to the device list. Without the flag the key is kept, so
  /// a replacement device picks up exactly where the old one left off.
  Future<void> restoreBackupData(
    String rawData, {
    String? passphrase,
    bool asNewDevice = false,
  }) async {

    // Backups written by 0.4.7 and earlier with a passphrase contain the
    // string `placeholder_vault_blob` and no key material. Reject them loudly
    // rather than wiping a working identity with an empty one.
    if (rawData.contains('placeholder_vault_blob')) {
      throw Exception(
        'This backup was created by a version whose passphrase encryption was '
        'a placeholder — it contains no key material and cannot be restored.',
      );
    }

    late final Map<String, dynamic> data;
    try {
      final decoded = Vault.looksLikeVault(rawData)
          ? await Vault.open(vault: rawData, passphrase: passphrase ?? '')
          : utf8.decode(base64Decode(rawData));
      data = jsonDecode(decoded) as Map<String, dynamic>;
    } on VaultException {
      rethrow;
    } catch (e) {
      throw Exception('Backup file is corrupt or not a Spheres backup');
    }

    final version = data['version'];
    if (version is! int || version > formatVersion) {
      throw Exception('Unsupported backup format (version $version)');
    }

    final keypair = data['keypair'];
    if (keypair is! Map<String, dynamic> ||
        keypair['key'] is! String ||
        keypair['secret'] is! String ||
        (keypair['key'] as String).isEmpty ||
        (keypair['secret'] as String).isEmpty) {
      throw Exception('Backup contains no identity keypair — refusing to restore');
    }

    // Validated: safe to overwrite.
    final prefs = SecureStore.instance;

    if (data['identity'] != null) {
      await prefs.setString('spheres_identity_profile', jsonEncode(data['identity']));
    }

    await prefs.setString('spheres_identity_pubkey', keypair['key'] as String);
    await _secureStorage.write(
      key: 'spheres_identity_secret',
      value: keypair['secret'] as String,
    );

    // The X25519 key is restored when present. Without it a new one is
    // generated on load, which is safe but silently invalidates every existing
    // pairwise session until contacts pick up the new prekey.
    final exchangeSecret = keypair['exchangeSecret'];
    if (asNewDevice) {
      await _secureStorage.delete(key: 'spheres_identity_x25519_secret');
    } else if (exchangeSecret is String && exchangeSecret.isNotEmpty) {
      await _secureStorage.write(
        key: 'spheres_identity_x25519_secret',
        value: exchangeSecret,
      );
    }

    final store = data['store'];
    if (store is Map) {
      // Version 3 and later: restore everything verbatim.
      for (final entry in store.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! String) continue;
        // Never write keys a backup should not be able to set.
        if (!isBackedUpKey(key)) continue;
        await prefs.setString(key, value);
      }
    } else {
      // Version 2: only the flat fields existed.
      if (data['contacts'] != null) {
        await prefs.setString('spheres_contacts', jsonEncode(data['contacts']));
      }
      if (data['posts'] != null) {
        await prefs.setString('spheres_feed_posts', jsonEncode(data['posts']));
      }
    }

    DebugLogService().success('Backup', 'Data restored successfully');
  }
}
