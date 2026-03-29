import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rust_core_service.dart';
import 'debug_log_service.dart';

/// Handles creation and restoration of encrypted network backups.
class BackupService extends ChangeNotifier {
  final RustCoreService _rustCore = RustCoreService();

  /// Create a full backup bundle and encrypt it with a passphrase.
  Future<String> createBackup({String? passphrase}) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Collect all essential data
    final identity = prefs.getString('spheres_identity_profile');
    final contacts = prefs.getString('spheres_contacts');
    final posts = prefs.getString('spheres_feed_posts'); // We will filter for "my" posts later
    final keypair = prefs.getString('spheres_identity_keypair');

    final payload = {
      'identity': identity != null ? jsonDecode(identity) : null,
      'keypair': keypair != null ? jsonDecode(keypair) : null,
      'contacts': contacts != null ? jsonDecode(contacts) : [],
      'posts': posts != null ? jsonDecode(posts) : [],
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
    };

    final payloadJson = jsonEncode(payload);
    String finalData;

    if (passphrase != null && passphrase.isNotEmpty) {
      // 2. Encrypt via Rust Core
      final result = _rustCore.createVault(payloadJson, passphrase);
      if (result == null) throw Exception('Vault encryption failed');
      finalData = result;
    } else {
      finalData = base64Encode(utf8.encode(payloadJson));
    }

    // 3. Save to file
    final dir = await getApplicationDocumentsDirectory();
    final backupDir = Directory('${dir.path}/backups');
    if (!backupDir.existsSync()) await backupDir.create();

    final fileName = 'spheres_backup_${DateTime.now().millisecondsSinceEpoch}.spheres';
    final file = File('${backupDir.path}/$fileName');
    await file.writeAsString(finalData);

    DebugLogService().success('Backup', 'Vault backup created: $fileName');
    return file.path;
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
  Future<void> restoreBackup(String filePath, {String? passphrase}) async {
    final file = File(filePath);
    if (!file.existsSync()) throw Exception('Backup file not found');

    final rawData = await file.readAsString();
    String decryptedJson;

    if (passphrase != null && passphrase.isNotEmpty) {
      final result = _rustCore.unlockVault(rawData, passphrase);
      if (result == null) throw Exception('Failed to unlock vault. Incorrect passphrase?');
      decryptedJson = result;
    } else {
      decryptedJson = utf8.decode(base64Decode(rawData));
    }

    final data = jsonDecode(decryptedJson) as Map<String, dynamic>;
    
    // 4. Restore to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    
    if (data['identity'] != null) {
      await prefs.setString('spheres_identity_profile', jsonEncode(data['identity']));
    }
    if (data['keypair'] != null) {
      await prefs.setString('spheres_identity_keypair', jsonEncode(data['keypair']));
    }
    if (data['contacts'] != null) {
      await prefs.setString('spheres_contacts', jsonEncode(data['contacts']));
    }
    if (data['posts'] != null) {
      await prefs.setString('spheres_feed_posts', jsonEncode(data['posts']));
    }

    DebugLogService().success('Backup', 'Data restored successfully from vault');
  }
}
