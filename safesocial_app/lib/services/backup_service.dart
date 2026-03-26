import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages encrypted backup and restore of all user data.
///
/// Backup file contains: identity (keypair + profile), contacts,
/// conversations metadata, feed posts, and settings.
/// Protected by a user-chosen passphrase via simple XOR + base64
/// (placeholder — real implementation uses XChaCha20-Poly1305 via Veilid).
class BackupService {
  static const _backupVersion = 1;

  /// Create a full backup of all user data.
  /// Returns the file path of the backup file.
  Future<String> createBackup({String? passphrase}) async {
    final prefs = await SharedPreferences.getInstance();

    // Gather all Sphere data from SharedPreferences
    final backupData = <String, dynamic>{
      'version': _backupVersion,
      'created_at': DateTime.now().toIso8601String(),
      'identity': {
        'keypair': prefs.getString('sphere_identity_keypair'),
        'profile': prefs.getString('sphere_identity_profile'),
        'dht_key': prefs.getString('sphere_identity_dht_key'),
      },
      'contacts': prefs.getString('sphere_contacts'),
      'conversations': prefs.getString('sphere_conversations'),
      'feed_posts': prefs.getString('sphere_feed_posts'),
      'hidden_posts': prefs.getStringList('sphere_hidden_posts'),
      'theme_mode': prefs.getString('theme_mode'),
    };

    // Also gather cached messages
    final msgKeys = prefs.getKeys().where((k) => k.startsWith('sphere_msgs_'));
    final messages = <String, String?>{};
    for (final key in msgKeys) {
      messages[key] = prefs.getString(key);
    }
    backupData['messages'] = messages;

    // Serialize
    var jsonStr = jsonEncode(backupData);

    // Encrypt if passphrase provided
    if (passphrase != null && passphrase.isNotEmpty) {
      jsonStr = _xorEncrypt(jsonStr, passphrase);
      jsonStr = 'ENCRYPTED:${base64Encode(utf8.encode(jsonStr))}';
    }

    // Write to file
    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filePath = '${dir.path}/sphere_backup_$timestamp.ssb';
    final file = File(filePath);
    await file.writeAsString(jsonStr);

    debugPrint('[BackupService] Backup created at $filePath');
    return filePath;
  }

  /// Restore from a backup file.
  Future<void> restoreBackup(String filePath, {String? passphrase}) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw Exception('Backup file not found');
    }

    var content = await file.readAsString();

    // Decrypt if encrypted
    if (content.startsWith('ENCRYPTED:')) {
      if (passphrase == null || passphrase.isEmpty) {
        throw Exception('This backup is encrypted. Please provide the passphrase.');
      }
      final encoded = content.substring('ENCRYPTED:'.length);
      content = utf8.decode(base64Decode(encoded));
      content = _xorDecrypt(content, passphrase);
    }

    final backupData = jsonDecode(content) as Map<String, dynamic>;
    final version = backupData['version'] as int? ?? 0;
    if (version > _backupVersion) {
      throw Exception('Backup version $version is newer than supported ($_backupVersion)');
    }

    final prefs = await SharedPreferences.getInstance();

    // Restore identity
    final identity = backupData['identity'] as Map<String, dynamic>?;
    if (identity != null) {
      if (identity['keypair'] != null) {
        await prefs.setString('sphere_identity_keypair', identity['keypair'] as String);
      }
      if (identity['profile'] != null) {
        await prefs.setString('sphere_identity_profile', identity['profile'] as String);
      }
      if (identity['dht_key'] != null) {
        await prefs.setString('sphere_identity_dht_key', identity['dht_key'] as String);
      }
    }

    // Restore contacts
    if (backupData['contacts'] != null) {
      await prefs.setString('sphere_contacts', backupData['contacts'] as String);
    }

    // Restore conversations
    if (backupData['conversations'] != null) {
      await prefs.setString('sphere_conversations', backupData['conversations'] as String);
    }

    // Restore feed posts
    if (backupData['feed_posts'] != null) {
      await prefs.setString('sphere_feed_posts', backupData['feed_posts'] as String);
    }

    // Restore hidden posts
    final hidden = backupData['hidden_posts'];
    if (hidden != null) {
      await prefs.setStringList(
        'sphere_hidden_posts',
        (hidden as List<dynamic>).map((e) => e as String).toList(),
      );
    }

    // Restore theme
    if (backupData['theme_mode'] != null) {
      await prefs.setString('theme_mode', backupData['theme_mode'] as String);
    }

    // Restore cached messages
    final messages = backupData['messages'] as Map<String, dynamic>?;
    if (messages != null) {
      for (final entry in messages.entries) {
        if (entry.value != null) {
          await prefs.setString(entry.key, entry.value as String);
        }
      }
    }

    // Restore friend requests
    if (backupData['friend_requests'] != null) {
      await prefs.setString('sphere_friend_requests', backupData['friend_requests'] as String);
    }

    debugPrint('[BackupService] Backup restored from $filePath');
  }

  /// List available backup files.
  Future<List<FileSystemEntity>> listBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .where((f) => f.path.endsWith('.ssb'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  // Simple XOR cipher — placeholder for real encryption
  String _xorEncrypt(String data, String key) {
    final keyBytes = utf8.encode(key);
    final dataBytes = utf8.encode(data);
    final result = List<int>.generate(
      dataBytes.length,
      (i) => dataBytes[i] ^ keyBytes[i % keyBytes.length],
    );
    return base64Encode(result);
  }

  String _xorDecrypt(String data, String key) {
    final keyBytes = utf8.encode(key);
    final dataBytes = base64Decode(data);
    final result = List<int>.generate(
      dataBytes.length,
      (i) => dataBytes[i] ^ keyBytes[i % keyBytes.length],
    );
    return utf8.decode(result);
  }
}
