import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';

import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'veilid_service.dart';

/// Manages the user's cryptographic identity and profile.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsKeypairKey = 'spheres_identity_keypair';

  final VeilidService veilidService;
  UserProfile? _currentIdentity;
  KeyPair? _keypair;

  IdentityService({required this.veilidService});

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.key.toString();
  bool get isOnboarded => _currentIdentity != null;

  /// Generate a new identity keypair and profile.
  Future<void> createIdentity(String displayName, {String? bio}) async {
    try {
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

  /// Export the current identity keypair as a JSON string.
  Future<String> exportIdentity() async {
    if (_keypair == null) throw Exception('No identity to export');
    return jsonEncode({
      'key': _keypair!.key.toString(),
      'secret': _keypair!.secret.toString(),
    });
  }

  /// Import an identity from a JSON string.
  Future<bool> importIdentity(String json, {String? displayName}) async {
    try {
      final data = jsonDecode(json);
      // Logic for importing existing identity would go here
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
      final profileJson = prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        _currentIdentity = UserProfile.fromJson(jsonDecode(profileJson));
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[IdentityService] Load failed: $e');
    }
  }

  /// PERSISTENT MEMORY: Reset everything.
  /// Clears all local storage and effectively 'factory resets' the app.
  Future<void> resetEverything() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    // Clear in-memory state
    _currentIdentity = null;
    _keypair = null;
    
    DebugLogService().warn('Identity', 'All data has been wiped from this device');
    notifyListeners();
  }

  Future<void> _persistIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_keypair != null) await prefs.setString(_prefsKeypairKey, _keypair!.key.toString());
      if (_currentIdentity != null) await prefs.setString(_prefsProfileKey, jsonEncode(_currentIdentity!.toJson()));
    } catch (e) {
      debugPrint('[IdentityService] SharedPreferences persist failed: $e');
    }
  }
}
