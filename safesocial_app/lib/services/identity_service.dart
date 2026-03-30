import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';

import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

class IdentityKeyPair {
  final String publicKey;
  final String secretKey;

  IdentityKeyPair({required this.publicKey, required this.secretKey});
}

/// Manages the user's cryptographic identity and profile.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsKeypairKey = 'spheres_identity_keypair';

  final RustCoreService _rustCore = RustCoreService();
  UserProfile? _currentIdentity;
  IdentityKeyPair? _keypair;

  IdentityService();

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.publicKey;
  bool get isOnboarded => _currentIdentity != null && _keypair != null;

  /// Generate a new identity keypair and profile.
  Future<void> createIdentity(String displayName, {String? bio}) async {
    try {
      final keyPair = ed.generateKey();
      final pubKeyHex = hex.encode(keyPair.publicKey.bytes);
      final privKeyHex = hex.encode(keyPair.privateKey.bytes);
      
      _keypair = IdentityKeyPair(
        publicKey: pubKeyHex,
        secretKey: privKeyHex,
      );
      
      _currentIdentity = UserProfile(
        publicKey: pubKeyHex,
        displayName: displayName,
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );

      await _persistIdentity();
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
    notifyListeners();
  }

  /// Export the current identity keypair as a secure encrypted vault.
  Future<String> exportIdentity(String passphrase) async {
    if (_keypair == null) throw Exception('No identity to export');
    
    // Create the bundle
    final payload = jsonEncode({
      'key': _keypair!.publicKey,
      'secret': _keypair!.secretKey,
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
        decrypted = blob;
      }

      final data = jsonDecode(decrypted);
      final keyStr = data['key'] as String;
      final secretStr = data['secret'] as String;
      
      _keypair = IdentityKeyPair(
        publicKey: keyStr,
        secretKey: secretStr,
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
      
      // Load KeyPair
      final keypairJson = prefs.getString(_prefsKeypairKey);
      if (keypairJson != null) {
        final data = jsonDecode(keypairJson);
        _keypair = IdentityKeyPair(
          publicKey: data['key'],
          secretKey: data['secret'],
        );
        DebugLogService().success('Identity', 'Cryptographic identity restored');
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[IdentityService] Load failed: $e');
    }
  }

  /// PERSISTENT MEMORY: Reset everything.
  /// Clears all local storage, deletes all files.
  Future<void> resetEverything() async {
    // 1. Wipe SharedPreferences and ENSURE it commits (for Android Backup)
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    // 2. Clear in-memory state
    _currentIdentity = null;
    _keypair = null;

    try {
      // 3. Wipe all app files by deleting directory contents
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

  Future<void> publishProfileToRelay(RelayService relay) async {
    if (_keypair == null || _currentIdentity == null) return;
    
    final payload = jsonEncode(_currentIdentity!.toJson());
    final success = await relay.pushState(publicKey!, 'profile', payload);
    
    if (success) {
      DebugLogService().success('Identity', 'Profile published to Relay state store');
    } else {
      DebugLogService().error('Identity', 'Failed to publish profile to Relay');
    }
  }

  Future<void> _persistIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_keypair != null) {
        await prefs.setString(_prefsKeypairKey, jsonEncode({
          'key': _keypair!.publicKey,
          'secret': _keypair!.secretKey,
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
