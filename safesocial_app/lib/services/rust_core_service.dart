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

typedef _SpheresStringFreeNative = ffi.Void Function(ffi.Pointer<ffi.Char> s);
typedef _SpheresStringFreeFunc = void Function(ffi.Pointer<ffi.Char> s);
