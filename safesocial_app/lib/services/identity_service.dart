import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'secure_store.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:cryptography/cryptography.dart';

import '../crypto/device.dart';
import '../crypto/spheres_crypto.dart';
import '../crypto/vault.dart';
import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'relay_config.dart';
import 'relay_service.dart';

class IdentityKeyPair {
  final String publicKey;
  final String secretKey;

  IdentityKeyPair({required this.publicKey, required this.secretKey});
}

/// Manages the user's cryptographic identity and profile.
///
/// An identity is two key pairs with separate jobs:
///
/// * **Ed25519** — signs everything. This is the public key others know you by,
///   the one in your QR code, and the one that has to stay stable.
/// * **X25519** — key agreement only, for deriving pairwise secrets.
///
/// They are separate rather than one converted into the other: the Ed25519 →
/// X25519 birational map is easy to get subtly wrong (the previous Rust
/// implementation returned 32 zero bytes), and publishing a distinct key costs
/// nothing since profiles are signed anyway.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsPubKeyKey = 'spheres_identity_pubkey';
  static const _secureSecretKey = 'spheres_identity_secret';
  static const _secureExchangeSecretKey = 'spheres_identity_x25519_secret';
  static const _secureDeviceIdKey = 'spheres_device_id';
  static const _prefsDevicesKey = 'spheres_devices_v1';

  final _secureStorage = const FlutterSecureStorage();

  UserProfile? _currentIdentity;
  IdentityKeyPair? _keypair;
  SimpleKeyPair? _exchangeKeyPair;
  String? _exchangePublicKeyHex;

  /// This install's device id, and the signed list of every device this
  /// identity uses. See [DeviceList] for what revocation can and cannot do.
  String? _deviceId;
  DeviceList? _deviceList;

  /// Fired when the device list changes here, so the app can publish the new
  /// bundle and tell contacts and our other devices.
  void Function(DeviceList list)? onDeviceListChanged;

  IdentityService();

  String? get deviceId => _deviceId;
  DeviceList? get deviceList => _deviceList;

  /// True when a newer list from another of our devices no longer includes
  /// this one. Contacts have stopped sending here; the UI should say so.
  bool get thisDeviceRevoked {
    final list = _deviceList;
    final key = _exchangePublicKeyHex;
    return list != null && key != null && !list.hasExchangeKey(key);
  }

  /// Every X25519 device key this identity uses, this device included.
  List<String> get deviceExchangeKeys {
    final list = _deviceList;
    if (list != null && list.devices.isNotEmpty) return list.exchangeKeys;
    final key = _exchangePublicKeyHex;
    return key == null ? const [] : [key];
  }

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.publicKey;
  String? get secretKey => _keypair?.secretKey;
  bool get isOnboarded => _currentIdentity != null && _keypair != null;

  /// Our X25519 key pair, used to derive pairwise secrets with contacts.
  SimpleKeyPair? get exchangeKeyPair => _exchangeKeyPair;

  /// Our X25519 public key as hex, as published in the profile.
  String? get exchangePublicKey => _exchangePublicKeyHex;

  /// Create the X25519 key pair if this identity does not have one yet.
  ///
  /// Identities created before Phase 1 have only an Ed25519 key, so this runs
  /// on load as a migration. The Ed25519 key is never regenerated — that would
  /// change the user's identity and break every existing contact.
  Future<void> _ensureExchangeKeyPair() async {
    if (_exchangeKeyPair != null) return;

    final stored = await _secureStorage.read(key: _secureExchangeSecretKey);
    if (stored != null) {
      try {
        _exchangeKeyPair = await SpheresCrypto.keyExchangeKeyPairFromPrivateBytes(
          hex.decode(stored),
        );
        _exchangePublicKeyHex =
            hex.encode((await _exchangeKeyPair!.extractPublicKey()).bytes);
        return;
      } catch (e) {
        DebugLogService()
            .error('Identity', 'Stored exchange key unreadable, regenerating: $e');
      }
    }

    final pair = await SpheresCrypto.newKeyExchangeKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    await _secureStorage.write(
      key: _secureExchangeSecretKey,
      value: hex.encode(privateBytes),
    );

    _exchangeKeyPair = pair;
    _exchangePublicKeyHex = hex.encode((await pair.extractPublicKey()).bytes);
    DebugLogService().info('Identity', 'Key exchange keypair ready');
    // A new device key means a new device entry; the old one, if any, stays
    // listed until revoked — it may be a phone that is still in use.
    await _ensureDeviceListed();

    // Publish it so contacts can start encrypting to us.
    if (_currentIdentity != null &&
        _currentIdentity!.keyExchangePublicKey != _exchangePublicKeyHex) {
      _currentIdentity = _currentIdentity!.copyWith(
        keyExchangePublicKey: _exchangePublicKeyHex,
        updatedAt: DateTime.now(),
      );
      await _persistIdentity();
    }
  }

  // ── Devices ───────────────────────────────────────────────────────────────

  Future<String> _ensureDeviceId() async {
    final existing = _deviceId ?? await _secureStorage.read(key: _secureDeviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      _deviceId = existing;
      return existing;
    }
    final id = hex.encode(SpheresCrypto.randomBytes(8));
    await _secureStorage.write(key: _secureDeviceIdKey, value: id);
    _deviceId = id;
    return id;
  }

  Future<void> _loadDeviceList() async {
    if (_deviceList != null) return;
    final raw = await SecureStore.instance.getString(_prefsDevicesKey);
    if (raw == null) return;
    try {
      final list = DeviceList.fromJson(jsonDecode(raw));
      if (list != null && list.verify() && list.identityKey == _keypair?.publicKey) {
        _deviceList = list;
      }
    } catch (_) {
      // Rebuilt below from this device alone.
    }
  }

  /// Make sure this device's key is in the signed list, signing a new list if
  /// it is not. Runs whenever the exchange key is established.
  Future<void> _ensureDeviceListed() async {
    final keypair = _keypair;
    final xk = _exchangePublicKeyHex;
    if (keypair == null || xk == null) return;
    await _loadDeviceList();
    final id = await _ensureDeviceId();

    final current = _deviceList;
    if (current != null && current.hasExchangeKey(xk)) return;

    final cert = DeviceCert.issue(
      identityKey: keypair.publicKey,
      identitySecret: keypair.secretKey,
      deviceId: id,
      exchangeKey: xk,
      name: _defaultDeviceName(),
    );
    final devices = [
      ...?current?.devices.where((d) => d.deviceId != id),
      cert,
    ];
    await _adoptOwnList(DeviceList.sign(
      identityKey: keypair.publicKey,
      identitySecret: keypair.secretKey,
      devices: devices,
    ));
  }

  static String _defaultDeviceName() {
    try {
      return 'This ${Platform.operatingSystem} device';
    } catch (_) {
      return 'This device';
    }
  }

  Future<void> _adoptOwnList(DeviceList list) async {
    _deviceList = list;
    await SecureStore.instance.setString(
      _prefsDevicesKey,
      jsonEncode(list.toJson(includeNames: true)),
    );
    notifyListeners();
    onDeviceListChanged?.call(list);
  }

  /// Stop sending to a device. It keeps whatever it already has, and it still
  /// holds the identity secret — see [DeviceList].
  Future<void> revokeDevice(String deviceId) async {
    final keypair = _keypair;
    final list = _deviceList;
    if (keypair == null || list == null) return;
    if (deviceId == _deviceId) {
      throw StateError('Revoke this device from another one, or reset it.');
    }
    final remaining = list.devices.where((d) => d.deviceId != deviceId).toList();
    if (remaining.length == list.devices.length) return;
    await _adoptOwnList(DeviceList.sign(
      identityKey: keypair.publicKey,
      identitySecret: keypair.secretKey,
      devices: remaining,
    ));
  }

  /// Label a device for our own list. Not signed and never sent.
  Future<void> renameDevice(String deviceId, String name) async {
    final list = _deviceList;
    if (list == null) return;
    final devices = list.devices
        .map((d) => d.deviceId == deviceId ? d.withName(name.trim()) : d)
        .toList();
    _deviceList = DeviceList(
      identityKey: list.identityKey,
      devices: devices,
      version: list.version,
      signature: list.signature,
    );
    await SecureStore.instance.setString(
      _prefsDevicesKey,
      jsonEncode(_deviceList!.toJson(includeNames: true)),
    );
    notifyListeners();
  }

  /// A signed list from one of our other devices. Adopted when it is newer
  /// and verifies; local names are kept.
  Future<bool> adoptDeviceList(Object? json) async {
    final keypair = _keypair;
    if (keypair == null) return false;
    final list = DeviceList.fromJson(json);
    if (list == null || list.identityKey != keypair.publicKey || !list.verify()) {
      return false;
    }
    final current = _deviceList;
    if (current != null && list.version <= current.version) return false;

    final named = list.devices
        .map((d) => d.withName(current?.byId(d.deviceId)?.name ?? d.name))
        .toList();
    _deviceList = DeviceList(
      identityKey: list.identityKey,
      devices: named,
      version: list.version,
      signature: list.signature,
    );
    await SecureStore.instance.setString(
      _prefsDevicesKey,
      jsonEncode(_deviceList!.toJson(includeNames: true)),
    );
    notifyListeners();
    return true;
  }

  /// Issue a certificate for a device being linked, and add it to the list.
  Future<DeviceList?> addLinkedDevice({
    required String deviceId,
    required String exchangeKey,
    String? name,
  }) async {
    final keypair = _keypair;
    if (keypair == null) return null;
    await _loadDeviceList();
    final list = _deviceList;
    if (list != null && list.hasExchangeKey(exchangeKey)) return list;
    final cert = DeviceCert.issue(
      identityKey: keypair.publicKey,
      identitySecret: keypair.secretKey,
      deviceId: deviceId,
      exchangeKey: exchangeKey,
      name: name,
    );
    await _adoptOwnList(DeviceList.sign(
      identityKey: keypair.publicKey,
      identitySecret: keypair.secretKey,
      devices: [...?list?.devices.where((d) => d.deviceId != deviceId), cert],
    ));
    return _deviceList;
  }

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

      // Must exist before the profile is built, so the profile carries it.
      _exchangeKeyPair = null;
      await _ensureExchangeKeyPair();

      _currentIdentity = UserProfile(
        publicKey: pubKeyHex,
        keyExchangePublicKey: _exchangePublicKeyHex,
        displayName: displayName,
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );

      await _persistIdentity();
      _logInviteLinkForDebugging();
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Identity', 'Failed to create identity: $e');
      rethrow;
    }
  }

  /// Fired after the profile changes, so the app can tell contacts. Set by
  /// the app.
  Future<void> Function(UserProfile profile)? onProfileChanged;

  /// Update the user's profile information.
  Future<void> updateProfile({String? displayName, String? bio, String? birthday}) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      displayName: displayName ?? _currentIdentity!.displayName,
      bio: bio ?? _currentIdentity!.bio,
      birthday: birthday ?? _currentIdentity!.birthday,
      updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    notifyListeners();
    await onProfileChanged?.call(_currentIdentity!);
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
    await onProfileChanged?.call(_currentIdentity!);
  }

  /// Export the current identity as a passphrase-encrypted vault.
  ///
  /// The vault primitives this used to depend on returned a fixed string
  /// regardless of input, so an "encrypted" export contained no key material.
  /// It is now real Argon2id + XChaCha20-Poly1305 (see [Vault]). The result is
  /// safe to put on a clipboard only because it is encrypted — never export
  /// the raw key that way.
  Future<String> exportIdentity(String passphrase) async {
    if (_keypair == null) throw Exception('No identity to export');

    return Vault.seal(
      plaintext: jsonEncode({
        'key': _keypair!.publicKey,
        'secret': _keypair!.secretKey,
        'profile': _currentIdentity?.toJson(),
        if (_deviceList != null) 'devices': _deviceList!.toJson(),
      }),
      passphrase: passphrase,
    );
  }

  /// Import an identity, from a vault or an unencrypted blob.
  Future<bool> importIdentity(String blob, {String? passphrase}) async {
    try {
      final decoded = Vault.looksLikeVault(blob)
          ? await Vault.open(vault: blob, passphrase: passphrase ?? '')
          : blob;
      final data = jsonDecode(decoded);
      if (data is! Map ||
          data['key'] is! String ||
          data['secret'] is! String ||
          (data['key'] as String).isEmpty ||
          (data['secret'] as String).isEmpty) {
        debugPrint('[IdentityService] Import rejected: no valid keypair in blob');
        return false;
      }

      _keypair = IdentityKeyPair(
        publicKey: data['key'] as String,
        secretKey: data['secret'] as String,
      );

      if (data['profile'] != null) {
        _currentIdentity = UserProfile.fromJson(data['profile']);
      }

      // A restored identity may predate key exchange, or its X25519 secret may
      // not have travelled with it. Either way, establish one now — this
      // device gets its own key and adds itself to the device list.
      _exchangeKeyPair = null;
      _exchangePublicKeyHex = null;
      _deviceList = null;
      if (data['devices'] != null) {
        final list = DeviceList.fromJson(data['devices']);
        if (list != null && list.identityKey == _keypair!.publicKey && list.verify()) {
          _deviceList = list;
          await SecureStore.instance.setString(
              _prefsDevicesKey, jsonEncode(list.toJson(includeNames: true)));
        }
      }
      await _ensureExchangeKeyPair();
      await _ensureDeviceListed();

      await _persistIdentity();
      notifyListeners();
      return true;
    } on VaultException {
      // Let this through: "wrong passphrase" and "this is not a backup" are
      // different problems and the user can act on the difference.
      rethrow;
    } catch (e) {
      debugPrint('[IdentityService] Import failed: $e');
      return false;
    }
  }

  /// Load identity from local storage (hybrid Secure + SharedPrefs).
  Future<void> loadIdentity() async {
    try {
      final prefs = SecureStore.instance;
      
      final profileJson = await prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        _currentIdentity = UserProfile.fromJson(jsonDecode(profileJson));
      }
      
      final pubKey = await prefs.getString(_prefsPubKeyKey);
      final secretKey = await _secureStorage.read(key: _secureSecretKey);

      if (pubKey != null && secretKey != null) {
        _keypair = IdentityKeyPair(publicKey: pubKey, secretKey: secretKey);
        await _ensureExchangeKeyPair();
        await _ensureDeviceListed();
        DebugLogService().success('Identity', 'Secure identity restored');
      } else {
        // Migration from old SharedPreferences keypair if exists
        final legacyJson = await prefs.getString('spheres_identity_keypair');
        if (legacyJson != null) {
          final data = jsonDecode(legacyJson);
          _keypair = IdentityKeyPair(publicKey: data['key'], secretKey: data['secret']);
          await _ensureExchangeKeyPair();
          await _persistIdentity(); // This will move it to secure storage
          await prefs.remove('spheres_identity_keypair');
          DebugLogService().info('Identity', 'Migrated identity to secure storage');
        }
      }
      
      _logInviteLinkForDebugging();
      notifyListeners();
    } catch (e) {
      debugPrint('[IdentityService] Load failed: $e');
    }
  }

  /// PERSISTENT MEMORY: Reset everything.
  Future<void> resetEverything() async {
    final prefs = SecureStore.instance;
    await prefs.clear();
    await _secureStorage.deleteAll();
    
    _currentIdentity = null;
    _keypair = null;
    _exchangeKeyPair = null;
    _exchangePublicKeyHex = null;
    _deviceId = null;
    _deviceList = null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      if (appDir.existsSync()) {
        final items = appDir.listSync();
        for (var item in items) {
          try { await item.delete(recursive: true); } catch (_) {}
        }
      }

      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final items = tempDir.listSync();
        for (var item in items) {
          try { await item.delete(recursive: true); } catch (_) {}
        }
      }
      DebugLogService().warn('Identity', 'HARD WIPE COMPLETE.');
    } catch (e) {
      DebugLogService().error('Identity', 'FileSystem wipe errors: $e');
    }
    
    notifyListeners();
  }

  /// Publish the minimum a stranger needs in order to encrypt to us.
  ///
  /// Only the identity key, the X25519 key, and a signature binding them
  /// together. Display name, bio and avatar are deliberately excluded: they
  /// used to be published to an unauthenticated endpoint, so anyone holding a
  /// public key could read them. Names now travel through the handshake, which
  /// only the intended recipient can read.
  Future<void> publishProfileToRelay(RelayService relay) async {
    if (_keypair == null) return;
    await _ensureExchangeKeyPair();
    final exchangeKey = _exchangePublicKeyHex;
    if (exchangeKey == null) return;

    final bundle = {
      'publicKey': _keypair!.publicKey,
      'keyExchangePublicKey': exchangeKey,
      // Where we listen. A contact on another relay sends here; that is the
      // whole federation mechanism, and it rides inside the signature so an
      // operator cannot redirect our mail.
      'relay': RelayConfig.primaryHost,
      // Every device we use, each with its own key, signed. A contact seals
      // once per device so that all of them can read.
      if (_deviceList != null) 'devices': _deviceList!.toJson(),
      'updatedAt': DateTime.now().toIso8601String(),
    };
    final bundleJson = jsonEncode(bundle);

    // Sign so a relay operator cannot substitute their own exchange key and
    // machine-in-the-middle new contacts.
    final privKey = ed.PrivateKey(hex.decode(_keypair!.secretKey));
    final signature = ed.sign(privKey, utf8.encode(bundleJson));

    final payload = jsonEncode({
      'bundle': bundle,
      'signature': hex.encode(signature),
    });

    final success = await relay.publishPrekey(
      _keypair!.publicKey,
      _keypair!.secretKey,
      payload,
    );

    if (success) {
      DebugLogService().success('Identity', 'Prekey bundle published');
    } else {
      DebugLogService().error('Identity', 'Failed to publish prekey bundle');
    }
  }

  /// Print this identity's invite link in debug builds only.
  ///
  /// Pairing goes through a QR scan, which two emulators cannot do to each
  /// other, and nothing else exposes the keys as text — they are encrypted at
  /// rest. Without this a two-device test cannot get past the first step.
  /// Both keys here are public; the secrets are never logged, and release
  /// builds never reach this line.
  void _logInviteLinkForDebugging() {
    if (!kDebugMode) return;
    final identity = _currentIdentity;
    if (identity == null) return;
    final exchangeKey = _exchangePublicKeyHex;
    debugPrint('[SpheresInvite] spheres://add?key=${identity.publicKey}'
        '&name=${Uri.encodeComponent(identity.displayName)}'
        '${exchangeKey != null ? '&xk=$exchangeKey' : ''}');
  }

  Future<void> _persistIdentity() async {
    try {
      final prefs = SecureStore.instance;
      if (_keypair != null) {
        await prefs.setString(_prefsPubKeyKey, _keypair!.publicKey);
        await _secureStorage.write(key: _secureSecretKey, value: _keypair!.secretKey);
      }
      if (_currentIdentity != null) {
        await prefs.setString(_prefsProfileKey, jsonEncode(_currentIdentity!.toJson()));
      }
    } catch (e) {
      debugPrint('[IdentityService] Persist failed: $e');
    }
  }
}
