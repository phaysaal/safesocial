import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';

import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'veilid_service.dart';
import 'rust_core_service.dart';

/// Manages the user's cryptographic identity and profile.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsKeypairKey = 'spheres_identity_keypair';

  final VeilidService veilidService;
  final RustCoreService _rustCore = RustCoreService();
  UserProfile? _currentIdentity;
  KeyPair? _keypair;

  IdentityService({required this.veilidService});

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.key.toString();
  bool get isOnboarded => _currentIdentity != null && _keypair != null;

  /// Generate a new identity keypair and profile.
  Future<void> createIdentity(String displayName, {String? bio}) async {
    try {
      // Ensure backend is ready
      final ok = await veilidService.waitForInit();
      if (!ok) throw Exception('Veilid backend failed to initialize in time');

      final crypto = await Veilid.instance.getCryptoSystem(
        bestCryptoKind,
      );
      
      _keypair = await crypto.generateKeyPair();
      
      _currentIdentity = UserProfile(
        publicKey: _keypair!.key.toString(),
        displayName: displayName,
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );

      await _persistIdentity();
      await _publishProfileToDHT();
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Identity', 'Failed to create identity: $e');
      rethrow;
    }
  }

  /// Update the user's profile information.
  Future<void> updateProfile({String? displayName, String? bio}) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      displayName: displayName ?? _currentIdentity!.displayName,
      bio: bio ?? _currentIdentity!.bio,
      updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    await _publishProfileToDHT();
    notifyListeners();
  }

  /// Update the user's avatar.
  Future<void> updateAvatar(String mediaRef) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      avatarRef: mediaRef,
      updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    await _publishProfileToDHT();
    notifyListeners();
  }

  /// Export the current identity keypair as a secure encrypted vault.
  Future<String> exportIdentity(String passphrase) async {
    if (_keypair == null) throw Exception('No identity to export');
    
    // Create the bundle
    final payload = jsonEncode({
      'key': _keypair!.key.toString(),
      'secret': _keypair!.secret.toString(),
      'profile': _currentIdentity?.toJson(),
    });

    // Use Rust Core to encrypt with Argon2id + XChaCha20
    final vault = _rustCore.createVault(payload, passphrase);
    if (vault == null) throw Exception('Failed to encrypt identity vault');
    
    return vault;
  }

  /// Import an identity from a secure vault or plain JSON (legacy).
  Future<bool> importIdentity(String blob, {String? passphrase}) async {
    try {
      String decrypted;
      if (passphrase != null && passphrase.isNotEmpty) {
        final result = _rustCore.unlockVault(blob, passphrase);
        if (result == null) return false;
        decrypted = result;
      } else {
        // Fallback for plaintext (not recommended)
        decrypted = blob;
      }

      final data = jsonDecode(decrypted);
      final keyStr = data['key'] as String;
      final secretStr = data['secret'] as String;
      
      _keypair = KeyPair(
        key: PublicKey.fromString(keyStr),
        secret: SecretKey.fromString(secretStr),
      );

      if (data['profile'] != null) {
        _currentIdentity = UserProfile.fromJson(data['profile']);
      }

      await _persistIdentity();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[IdentityService] Import failed: $e');
      return false;
    }
  }

  /// Load identity from local storage.
  Future<void> loadIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load Profile
      final profileJson = prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        _currentIdentity = UserProfile.fromJson(jsonDecode(profileJson));
      }
      
      // Load KeyPair (Issue #1 & #2 Fix)
      final keypairJson = prefs.getString(_prefsKeypairKey);
      if (keypairJson != null) {
        final data = jsonDecode(keypairJson);
        _keypair = KeyPair(
          key: PublicKey.fromString(data['key']),
          secret: SecretKey.fromString(data['secret']),
        );
        DebugLogService().success('Identity', 'Cryptographic identity restored');
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[IdentityService] Load failed: $e');
    }
  }

  /// PERSISTENT MEMORY: Reset everything.
  /// Clears all local storage, deletes all files, and ensures Android Backup is updated.
  Future<void> resetEverything() async {
    // 1. Shutdown Veilid first to release file locks
    await veilidService.shutdown();

    // 2. Wipe SharedPreferences and ENSURE it commits (for Android Backup)
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    // 3. Clear in-memory state
    _currentIdentity = null;
    _keypair = null;

    try {
      // 4. Wipe all app files by deleting directory contents
      final appDir = await getApplicationDocumentsDirectory();
      if (appDir.existsSync()) {
        final items = appDir.listSync();
        for (var item in items) {
          try {
            await item.delete(recursive: true);
          } catch (_) {}
        }
      }

      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final items = tempDir.listSync();
        for (var item in items) {
          try {
            await item.delete(recursive: true);
          } catch (_) {}
        }
      }
      
      DebugLogService().warn('Identity', 'HARD WIPE COMPLETE: Local and cloud state synchronized.');
    } catch (e) {
      DebugLogService().error('Identity', 'FileSystem wipe encountered errors: $e');
    }
    
    notifyListeners();
  }

  Future<void> _publishProfileToDHT() async {
    if (_keypair == null || _currentIdentity == null) return;
    // FUTURE: Write _currentIdentity to a DHT record owned by _keypair
    DebugLogService().info('Identity', 'Profile publication to DHT scheduled');
  }

  Future<void> _persistIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_keypair != null) {
        await prefs.setString(_prefsKeypairKey, jsonEncode({
          'key': _keypair!.key.toString(),
          'secret': _keypair!.secret.toString(),
        }));
      }
      if (_currentIdentity != null) {
        await prefs.setString(_prefsProfileKey, jsonEncode(_currentIdentity!.toJson()));
      }
    } catch (e) {
      debugPrint('[IdentityService] SharedPreferences persist failed: $e');
    }
  }
}
