import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/spheres_crypto.dart';
import 'debug_log_service.dart';

/// Encrypted-at-rest key/value storage for everything sensitive.
///
/// Message history, sphere keys, ratchet state, contacts and posts were
/// plaintext JSON in SharedPreferences. Anything able to read the app's data
/// directory — a rooted device, a forensic extraction, malware with the right
/// permissions — could read all of it, which undermined most of what the rest
/// of the system achieves. Forward secrecy in particular was largely
/// theoretical while the plaintext history sat on disk beside it.
///
/// **Why not SQLCipher.** The obvious answer is an encrypted database, and for
/// a project that can be run and tested that is the better one — it also brings
/// indexed queries, which this app will eventually want. It was not chosen here
/// because it is a native dependency, and this work cannot be executed or
/// built on a device: a plugin that fails to link would break the whole app in
/// a way no test here would catch. This achieves the same at-rest property
/// using primitives already in use, with no new native surface. Moving to
/// SQLCipher later is a storage-layer change behind this same interface.
///
/// What this does and does not give you:
///
/// * Values are sealed with XChaCha20-Poly1305 under a key held in the platform
///   keystore, so reading the data directory is no longer enough.
/// * The preference key is bound as associated data, so a value cannot be moved
///   from one key to another.
/// * **Key names remain visible**, as does the number and rough size of
///   entries. Someone reading the store learns that you have conversations and
///   roughly how many, but not with whom or what was said.
/// * It is not protection against a live compromised process, which can ask
///   the keystore for the key exactly as the app does.
class SecureStore {
  static const _keyName = 'spheres_store_key';
  static const _migratedFlag = 'spheres_store_encrypted_v1';
  static const _prefix = 'enc1:';

  static final SecureStore instance = SecureStore._();
  SecureStore._();

  final _keystore = const FlutterSecureStorage();
  Uint8List? _key;

  /// Keys holding sensitive data. Anything not listed stays plaintext —
  /// theme and relay host are neither secret nor worth the startup cost.
  static const List<String> sensitivePrefixes = [
    'spheres_identity_profile',
    'spheres_identity_pubkey',
    'spheres_contacts',
    'spheres_contact_requests_v1',
    'spheres_contact_declined_v1',
    'spheres_conversations',
    'spheres_msgs_',
    'spheres_sphere_msgs_',
    'spheres_archive_',
    'spheres_archive_index_v1',
    'spheres_sphere_chats_v1',
    'spheres_feed_posts',
    'spheres_hidden_posts',
    'spheres_spheres_v1',
    'spheres_keyring_v1',
    'spheres_invites_v1',
    // Who did what in which sphere, and who has been offered ownership of one.
    'spheres_sphere_audit_v1',
    'spheres_transfer_offers_v1',
    'spheres_removal_proposals_v1',
    'spheres_albums',
    'spheres_outbox_v1',
    'spheres_feed_outbox_v1',
    'spheres_sessions_v1',
    // Local curation. Saved posts are content ids, and muted spheres and
    // pinned chats reveal who someone talks to most — all worth encrypting.
    'spheres_saved_v1',
    'spheres_muted_spheres_v1',
    'spheres_pinned_chats_v1',
  ];

  static bool _isSensitive(String key) =>
      sensitivePrefixes.any((p) => key == p || key.startsWith(p));

  bool get isReady => _key != null;

  /// Load or create the store key, then migrate any plaintext left over.
  ///
  /// Must run before any service touches storage, or early reads would miss
  /// encrypted values and rewrite them in the clear.
  Future<void> init() async {
    final existing = await _keystore.read(key: _keyName);
    if (existing != null) {
      try {
        _key = Uint8List.fromList(hex.decode(existing));
      } catch (_) {
        _key = null;
      }
    }

    if (_key == null || _key!.length != SpheresCrypto.keyLength) {
      _key = SpheresCrypto.randomKey();
      await _keystore.write(key: _keyName, value: hex.encode(_key!));
      DebugLogService().info('Store', 'Created a new storage key');
    }

    await _migrate();
  }

  /// Encrypt anything still stored in the clear, once.
  Future<void> _migrate() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedFlag) == true) return;

    var migrated = 0;
    for (final key in prefs.getKeys().toList()) {
      if (!_isSensitive(key)) continue;
      String? value;
      try {
        value = prefs.getString(key);
      } catch (_) {
        // A StringList from before encryption; re-encode as JSON.
        try {
          final list = prefs.getStringList(key);
          if (list != null) value = jsonEncode(list);
        } catch (_) {
          value = null;
        }
      }
      if (value == null || value.startsWith(_prefix)) continue;

      await prefs.remove(key);
      await _write(prefs, key, value);
      migrated++;
    }

    await prefs.setBool(_migratedFlag, true);
    if (migrated > 0) {
      DebugLogService().success('Store', 'Encrypted $migrated stored value(s)');
    }
  }

  Future<void> _write(SharedPreferences prefs, String key, String value) async {
    final nonce = SpheresCrypto.randomNonce();
    final ciphertext = await SpheresCrypto.encrypt(
      key: _key!,
      nonce: nonce,
      plaintext: utf8.encode(value),
      // Binds the value to its key, so a stored blob cannot be relocated.
      aad: utf8.encode(key),
    );
    await prefs.setString(
      key,
      '$_prefix${base64Encode(nonce)}:${base64Encode(ciphertext)}',
    );
  }

  Future<String?> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw;
    try {
      raw = prefs.getString(key);
    } catch (_) {
      // Stored under a different type before encryption (e.g. a StringList).
      return null;
    }
    if (raw == null) return null;

    if (!raw.startsWith(_prefix)) {
      // Written before encryption, or not sensitive. Returned as-is; the
      // migration pass converts anything that should be encrypted.
      return raw;
    }
    if (_key == null) {
      DebugLogService().error('Store', 'Read before the store key was loaded');
      return null;
    }

    try {
      final parts = raw.substring(_prefix.length).split(':');
      if (parts.length != 2) return null;

      final plaintext = await SpheresCrypto.decrypt(
        key: _key!,
        nonce: base64Decode(parts[0]),
        ciphertextWithMac: base64Decode(parts[1]),
        aad: utf8.encode(key),
      );
      return utf8.decode(plaintext);
    } catch (e) {
      // A value that does not authenticate has been tampered with or the key
      // has changed. Returning null loses data; returning garbage would be
      // worse, and callers already tolerate a missing value.
      DebugLogService().error('Store', 'Could not decrypt "$key": $e');
      return null;
    }
  }

  Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!_isSensitive(key) || _key == null) {
      await prefs.setString(key, value);
      return;
    }
    await _write(prefs, key, value);
  }

  /// Booleans and other non-sensitive scalars pass straight through: they
  /// carry no content, and encrypting them would only obscure the fact that a
  /// setting exists.
  Future<bool?> getBool(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key);
  }

  Future<void> setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  /// Stored as an encrypted JSON array when the key is sensitive, so hidden
  /// post ids do not sit in the clear.
  Future<List<String>?> getStringList(String key) async {
    if (!_isSensitive(key)) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(key);
    }

    final raw = await getString(key);
    if (raw == null) {
      // Might predate encryption, when it really was a StringList.
      final prefs = await SharedPreferences.getInstance();
      try {
        return prefs.getStringList(key);
      } catch (_) {
        return null;
      }
    }
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {
      return null;
    }
  }

  Future<void> setStringList(String key, List<String> value) async {
    if (!_isSensitive(key)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(key, value);
      return;
    }
    await setString(key, jsonEncode(value));
  }

  /// Remove everything, including the key, so any residue is unreadable.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await clearKey();
  }

  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<Set<String>> getKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getKeys();
  }

  /// Wipe the store key too, so anything left on disk is unreadable.
  Future<void> clearKey() async {
    await _keystore.delete(key: _keyName);
    _key = null;
  }
}
