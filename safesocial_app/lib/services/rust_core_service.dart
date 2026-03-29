import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Service that interfaces with the Rust safesocial_core via FFI.
class RustCoreService extends ChangeNotifier {
  static final RustCoreService _instance = RustCoreService._internal();
  factory RustCoreService() => _instance;
  RustCoreService._internal();

  late ffi.DynamicLibrary _lib;
  ffi.Pointer? _handle;

  // Function signatures
  late _SpheresNewFunc _spheresNew;
  late _SpheresFreeFunc _spheresFree;
  late _SpheresInitiateSessionFunc _spheresInitiateSession;
  late _SpheresSendMessageFunc _spheresSendMessage;
  late _SpheresExportIdentityFunc _spheresExportIdentity;
  late _SpheresImportIdentityFunc _spheresImportIdentity;
  late _SpheresCreateVaultFunc _spheresCreateVault;
  late _SpheresUnlockVaultFunc _spheresUnlockVault;
  late _SpheresStringFreeFunc _spheresStringFree;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final String libPath = Platform.isAndroid 
          ? 'libsafesocial_core.so' 
          : Platform.isIOS 
              ? 'safesocial_core.framework/safesocial_core'
              : 'libsafesocial_core.so'; // Default

      _lib = ffi.DynamicLibrary.open(libPath);

      _spheresNew = _lib
          .lookup<ffi.NativeFunction<_SpheresNewNative>>('spheres_new')
          .asFunction();
      _spheresFree = _lib
          .lookup<ffi.NativeFunction<_SpheresFreeNative>>('spheres_free')
          .asFunction();
      _spheresInitiateSession = _lib
          .lookup<ffi.NativeFunction<_SpheresInitiateSessionNative>>('spheres_initiate_session')
          .asFunction();
      _spheresSendMessage = _lib
          .lookup<ffi.NativeFunction<_SpheresSendMessageNative>>('spheres_send_message')
          .asFunction();
      _spheresExportIdentity = _lib
          .lookup<ffi.NativeFunction<_SpheresExportIdentityNative>>('spheres_export_identity')
          .asFunction();
      _spheresImportIdentity = _lib
          .lookup<ffi.NativeFunction<_SpheresImportIdentityNative>>('spheres_import_identity')
          .asFunction();
      _spheresCreateVault = _lib
          .lookup<ffi.NativeFunction<_SpheresCreateVaultNative>>('spheres_create_vault')
          .asFunction();
      _spheresUnlockVault = _lib
          .lookup<ffi.NativeFunction<_SpheresUnlockVaultNative>>('spheres_unlock_vault')
          .asFunction();
      _spheresStringFree = _lib
          .lookup<ffi.NativeFunction<_SpheresStringFreeNative>>('spheres_string_free')
          .asFunction();

      final docsDir = await getApplicationDocumentsDirectory();
      final stateDirPtr = docsDir.path.toNativeUtf8();
      
      _handle = _spheresNew(stateDirPtr.cast<ffi.Char>());
      malloc.free(stateDirPtr);

      if (_handle != null) {
        _isInitialized = true;
        notifyListeners();
        debugPrint('[RustCore] Initialized successfully');
      }
    } catch (e) {
      debugPrint('[RustCore] Initialization failed: $e');
    }
  }

  void initiateSession(String contactKey, String sharedSecretBase64) {
    if (!_isInitialized || _handle == null) return;

    final contactPtr = contactKey.toNativeUtf8();
    final secretPtr = sharedSecretBase64.toNativeUtf8();

    final resultPtr = _spheresInitiateSession(
      _handle!,
      contactPtr.cast<ffi.Char>(),
      secretPtr.cast<ffi.Char>()
    );

    malloc.free(contactPtr);
    malloc.free(secretPtr);

    _spheresStringFree(resultPtr);
  }

  String? exportIdentity(String sessionSecretBase64) {
    if (!_isInitialized || _handle == null) return null;

    final secretPtr = sessionSecretBase64.toNativeUtf8();
    final resultPtr = _spheresExportIdentity(_handle!, secretPtr.cast<ffi.Char>());
    malloc.free(secretPtr);

    final result = resultPtr.cast<Utf8>().toDartString();
    _spheresStringFree(resultPtr);
    return result;
  }

  String? createVault(String payloadJson, String passphrase) {
    if (!_isInitialized || _handle == null) return null;

    final payloadPtr = payloadJson.toNativeUtf8();
    final passPtr = passphrase.toNativeUtf8();
    final resultPtr = _spheresCreateVault(_handle!, payloadPtr.cast<ffi.Char>(), passPtr.cast<ffi.Char>());
    
    malloc.free(payloadPtr);
    malloc.free(passPtr);

    final result = resultPtr.cast<Utf8>().toDartString();
    _spheresStringFree(resultPtr);
    return result;
  }

  String? unlockVault(String vaultBlobB64, String passphrase) {
    if (!_isInitialized || _handle == null) return null;

    final blobPtr = vaultBlobB64.toNativeUtf8();
    final passPtr = passphrase.toNativeUtf8();
    final resultPtr = _spheresUnlockVault(_handle!, blobPtr.cast<ffi.Char>(), passPtr.cast<ffi.Char>());
    
    malloc.free(blobPtr);
    malloc.free(passPtr);

    final result = resultPtr.cast<Utf8>().toDartString();
    _spheresStringFree(resultPtr);
    return result;
  }

  void importIdentity(String encryptedBlob, String sessionSecretBase64) {
    if (!_isInitialized || _handle == null) return;

    final blobPtr = encryptedBlob.toNativeUtf8();
    final secretPtr = sessionSecretBase64.toNativeUtf8();
    final resultPtr = _spheresImportIdentity(
      _handle!, 
      blobPtr.cast<ffi.Char>(), 
      secretPtr.cast<ffi.Char>()
    );
    
    malloc.free(blobPtr);
    malloc.free(secretPtr);
    _spheresStringFree(resultPtr);
  }

  void sendMessage(String recipientKey, String content) {
    if (!_isInitialized || _handle == null) return;

    final recipientPtr = recipientKey.toNativeUtf8();
    final contentPtr = content.toNativeUtf8();

    final resultPtr = _spheresSendMessage(
      _handle!, 
      recipientPtr.cast<ffi.Char>(), 
      contentPtr.cast<ffi.Char>()
    );

    malloc.free(recipientPtr);
    malloc.free(contentPtr);

    // Process result (JSON)
    final result = resultPtr.cast<Utf8>().toDartString();
    debugPrint('[RustCore] Send Message Result: $result');

    _spheresStringFree(resultPtr);
  }

  void dispose() {
    if (_handle != null) {
      _spheresFree(_handle!);
      _handle = null;
    }
    _isInitialized = false;
    super.dispose();
  }
}

// FFI type definitions
typedef _SpheresNewNative = ffi.Pointer Function(ffi.Pointer<ffi.Char> stateDir);
typedef _SpheresNewFunc = ffi.Pointer Function(ffi.Pointer<ffi.Char> stateDir);

typedef _SpheresFreeNative = ffi.Void Function(ffi.Pointer handle);
typedef _SpheresFreeFunc = void Function(ffi.Pointer handle);

typedef _SpheresInitiateSessionNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> contactKey, ffi.Pointer<ffi.Char> sharedSecretBase64);
typedef _SpheresInitiateSessionFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> contactKey, ffi.Pointer<ffi.Char> sharedSecretBase64);

typedef _SpheresSendMessageNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> recipientKey, ffi.Pointer<ffi.Char> content);
typedef _SpheresSendMessageFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> recipientKey, ffi.Pointer<ffi.Char> content);

typedef _SpheresExportIdentityNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> sessionSecretBase64);
typedef _SpheresExportIdentityFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> sessionSecretBase64);

typedef _SpheresImportIdentityNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> encryptedIdentityB64, ffi.Pointer<ffi.Char> sessionSecretBase64);
typedef _SpheresImportIdentityFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> encryptedIdentityB64, ffi.Pointer<ffi.Char> sessionSecretBase64);

typedef _SpheresCreateVaultNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> payloadJson, ffi.Pointer<ffi.Char> passphrase);
typedef _SpheresCreateVaultFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> payloadJson, ffi.Pointer<ffi.Char> passphrase);

typedef _SpheresUnlockVaultNative = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> vaultBlobB64, ffi.Pointer<ffi.Char> passphrase);
typedef _SpheresUnlockVaultFunc = ffi.Pointer<ffi.Char> Function(
    ffi.Pointer handle, ffi.Pointer<ffi.Char> vaultBlobB64, ffi.Pointer<ffi.Char> passphrase);

typedef _SpheresStringFreeNative = ffi.Void Function(ffi.Pointer<ffi.Char> s);
typedef _SpheresStringFreeFunc = void Function(ffi.Pointer<ffi.Char> s);
